// Package server is the stateless HTTPS endpoint for HP Lifestyle cloud analysis.
//
// Contract (docs/m8-cloud-endpoint.md):
//   - POST /v1/analyze, Content-Type application/json, body = hpl.cloud_payload.v1 (≤ 16 KB), header
//     X-HPL-Request-ID equal to the body's request_id. Response 200 = hpl.cloud_insights.v1 (≤ 64 KB).
//   - GET /healthz for load balancers.
//
// Stateless: no database, no disk, no cache, no cookies, no sessions; the payload lives in memory for one request.
// Logs carry route, status, latency and an error class only: never bodies, request ids, IPs, user agents, headers,
// App Attest key ids, or error text from the TLS stack (which includes client addresses).
package server

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"log"
	"log/slog"
	"mime"
	"net/http"
	"time"

	"github.com/mmaziesf/heartypatch-lifestyle-ios/server/internal/api"
	"github.com/mmaziesf/heartypatch-lifestyle-ios/server/internal/attest"
)

// Config wires the handler.
type Config struct {
	Analyzer       api.Analyzer
	Attest         attest.Verifier
	Logger         *slog.Logger
	MaxInFlight    int           // concurrent analyses; extra requests get 503 (no per-client state)
	AnalyzeTimeout time.Duration // per request
}

type handler struct {
	cfg Config
	sem chan struct{}
}

// New returns the full handler (routing, limits, logging, panic recovery).
func New(cfg Config) http.Handler {
	if cfg.Analyzer == nil {
		cfg.Analyzer = api.RulesAnalyzer{}
	}
	if cfg.Attest == nil {
		cfg.Attest = attest.Off{}
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.New(slog.NewJSONHandler(io.Discard, nil))
	}
	if cfg.MaxInFlight <= 0 {
		cfg.MaxInFlight = 32
	}
	if cfg.AnalyzeTimeout <= 0 {
		cfg.AnalyzeTimeout = 10 * time.Second
	}
	h := &handler{cfg: cfg, sem: make(chan struct{}, cfg.MaxInFlight)}
	return h
}

// result is what the access log may see: nothing request-specific beyond the outcome.
type result struct {
	status int
	class  string
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	route := "other"
	var res result
	defer func() {
		if p := recover(); p != nil {
			// The panic value may contain request data, so it is not logged.
			res = result{http.StatusInternalServerError, "panic"}
			writeErr(w, res)
		}
		h.cfg.Logger.LogAttrs(context.Background(), slog.LevelInfo, "request",
			slog.String("route", route), slog.Int("status", res.status), slog.String("class", res.class),
			slog.Int64("ms", time.Since(start).Milliseconds()))
	}()
	setCommonHeaders(w)
	switch r.URL.Path {
	case "/v1/analyze":
		route = "analyze"
		res = h.analyze(w, r)
	case "/healthz":
		route = "healthz"
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			res = result{http.StatusMethodNotAllowed, "method"}
			writeErr(w, res)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok\n")
		res = result{http.StatusOK, "ok"}
	default:
		res = result{http.StatusNotFound, "not_found"}
		writeErr(w, res)
	}
}

func (h *handler) analyze(w http.ResponseWriter, r *http.Request) result {
	fail := func(status int, class string) result {
		res := result{status, class}
		writeErr(w, res)
		return res
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		return fail(http.StatusMethodNotAllowed, "method")
	}
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
		return fail(http.StatusUnsupportedMediaType, "content_type")
	}
	if r.ContentLength > api.MaxPayloadBytes {
		return fail(http.StatusRequestEntityTooLarge, "too_large")
	}
	select {
	case h.sem <- struct{}{}:
		defer func() { <-h.sem }()
	default:
		w.Header().Set("Retry-After", "5")
		return fail(http.StatusServiceUnavailable, "busy")
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, api.MaxPayloadBytes))
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			return fail(http.StatusRequestEntityTooLarge, "too_large")
		}
		return fail(http.StatusBadRequest, "read")
	}
	// App Attest hook: the assertion signs SHA-256 of these exact bytes (= the hash the user approved on device).
	if err := h.cfg.Attest.Verify(r, sha256.Sum256(body)); err != nil {
		return fail(http.StatusUnauthorized, "attest")
	}
	p, err := api.Decode(body)
	if err != nil {
		return fail(http.StatusUnprocessableEntity, "schema")
	}
	if r.Header.Get("X-HPL-Request-ID") != p.ID() {
		return fail(http.StatusBadRequest, "request_id")
	}
	ctx, cancel := context.WithTimeout(r.Context(), h.cfg.AnalyzeTimeout)
	defer cancel()
	out, err := h.cfg.Analyzer.Analyze(ctx, p)
	if err != nil {
		return fail(http.StatusBadGateway, "analyzer")
	}
	out, err = api.CheckInsights(out, body)
	if err != nil || out.RequestID != p.ID() {
		return fail(http.StatusBadGateway, "analyzer_output")
	}
	resp, err := marshal(out)
	if err != nil || len(resp) > api.MaxResponseBytes {
		return fail(http.StatusBadGateway, "analyzer_output")
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(resp)
	return result{http.StatusOK, "ok"}
}

func marshal(v any) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return b, nil
}

func setCommonHeaders(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Strict-Transport-Security", "max-age=63072000")
	h.Set("Referrer-Policy", "no-referrer")
}

// Error bodies are a fixed code; nothing from the request is echoed.
func writeErr(w http.ResponseWriter, res result) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(res.status)
	_, _ = io.WriteString(w, `{"error":"`+res.class+`"}`)
}

// SilentErrorLog is for http.Server.ErrorLog. net/http writes TLS handshake failures and similar there, with the
// client's IP:port in the text, so it is replaced by a fixed event with no message.
func SilentErrorLog(logger *slog.Logger) *log.Logger {
	return log.New(fixedEvent{logger}, "", 0)
}

type fixedEvent struct{ l *slog.Logger }

func (f fixedEvent) Write(p []byte) (int, error) {
	f.l.LogAttrs(context.Background(), slog.LevelWarn, "http_server_error")
	return len(p), nil
}

// TLSConfig is TLS 1.3 only, matching the client's tlsMinimumSupportedProtocolVersion. No session tickets, so a
// resumed connection can't be tied to an earlier one.
func TLSConfig() *tls.Config {
	return &tls.Config{MinVersion: tls.VersionTLS13, SessionTicketsDisabled: true}
}
