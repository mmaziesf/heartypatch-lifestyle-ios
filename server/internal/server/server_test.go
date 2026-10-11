package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mmaziesf/heartypatch-lifestyle-ios/server/internal/api"
	"github.com/mmaziesf/heartypatch-lifestyle-ios/server/internal/attest"
)

const goldenID = "00000000-0000-4000-8000-000000000001"

func golden(t *testing.T) []byte {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "Fixtures", "cloud", "payload-28d.synthetic.json"))
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	_ = json.Compact(&buf, raw)
	return buf.Bytes()
}

type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *syncBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

func newServer(t *testing.T, cfg Config) (*httptest.Server, *syncBuf) {
	logs := &syncBuf{}
	cfg.Logger = slog.New(slog.NewJSONHandler(logs, nil))
	srv := httptest.NewUnstartedServer(New(cfg))
	srv.Config.ErrorLog = SilentErrorLog(cfg.Logger)
	srv.TLS = TLSConfig()
	srv.StartTLS()
	t.Cleanup(srv.Close)
	return srv, logs
}

func post(t *testing.T, srv *httptest.Server, body []byte, mutate func(*http.Request)) (*http.Response, []byte) {
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/v1/analyze", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-HPL-Request-ID", goldenID)
	if mutate != nil {
		mutate(req)
	}
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, b
}

func TestAnalyzeGolden(t *testing.T) {
	srv, _ := newServer(t, Config{})
	resp, b := post(t, srv, golden(t), nil)
	if resp.StatusCode != 200 {
		t.Fatalf("status %d %s", resp.StatusCode, b)
	}
	if resp.TLS.Version != 0x0304 {
		t.Fatal("not TLS 1.3")
	}
	for k, v := range map[string]string{"Cache-Control": "no-store", "Content-Type": "application/json", "X-Content-Type-Options": "nosniff"} {
		if resp.Header.Get(k) != v {
			t.Errorf("%s = %q", k, resp.Header.Get(k))
		}
	}
	if resp.Header.Get("Set-Cookie") != "" {
		t.Error("cookie set")
	}
	var out api.Insights
	if err := json.Unmarshal(b, &out); err != nil || out.RequestID != goldenID || out.Schema != api.InsightsSchema || len(out.Insights) != 5 {
		t.Fatalf("bad response %s", b)
	}
	if len(b) > api.MaxResponseBytes {
		t.Fatal("response too large")
	}
}

func TestRejectsWithFixedErrors(t *testing.T) {
	srv, _ := newServer(t, Config{})
	g := golden(t)
	cases := []struct {
		name   string
		body   []byte
		mut    func(*http.Request)
		status int
	}{
		{"wrong method", nil, func(r *http.Request) { r.Method = http.MethodGet }, 405},
		{"text/plain", g, func(r *http.Request) { r.Header.Set("Content-Type", "text/plain") }, 415},
		{"too large", append(append([]byte{}, g...), bytes.Repeat([]byte(" "), api.MaxPayloadBytes)...), nil, 413},
		{"schema", []byte(`{"schema":"hpl.cloud_payload.v1","name":"Arash"}`), nil, 422},
		{"id mismatch", g, func(r *http.Request) { r.Header.Set("X-HPL-Request-ID", "11111111-1111-4111-8111-111111111111") }, 400},
		{"id missing", g, func(r *http.Request) { r.Header.Del("X-HPL-Request-ID") }, 400},
	}
	for _, c := range cases {
		resp, b := post(t, srv, c.body, c.mut)
		if resp.StatusCode != c.status {
			t.Errorf("%s: status %d want %d", c.name, resp.StatusCode, c.status)
		}
		if !strings.HasPrefix(string(b), `{"error":"`) || strings.Contains(string(b), "Arash") {
			t.Errorf("%s: body %s", c.name, b)
		}
	}
	resp, err := srv.Client().Get(srv.URL + "/healthz")
	if err != nil || resp.StatusCode != 200 {
		t.Fatal("healthz")
	}
	resp.Body.Close()
}

// Endpoint logs contain no bodies, ids, addresses or headers (M6 exit criterion left open on the client side).
func TestLogsCarryNoRequestData(t *testing.T) {
	srv, logs := newServer(t, Config{Attest: attest.AppAttest{AppID: "T.app", Keys: attest.NewMemoryKeyStore()}})
	g := golden(t)
	canaries := []string{goldenID, "CANARY-ua", "CANARY-cookie", "CANARY-body", "CANARY-key", "127.0.0.1", "Mon", "breakfast", "12500"}
	withHeaders := func(r *http.Request) {
		r.Header.Set("User-Agent", "CANARY-ua")
		r.Header.Set("Cookie", "s=CANARY-cookie")
		r.Header.Set(attest.HeaderKeyID, "Q0FOQVJZLWtleQ==") // "CANARY-key"
		r.Header.Set(attest.HeaderAssertion, "oA==")
	}
	post(t, srv, g, withHeaders)                                // 401 attest
	post(t, srv, []byte(`{"name":"CANARY-body"}`), withHeaders) // 401 before parse
	srv2, logs2 := newServer(t, Config{})
	post(t, srv2, []byte(`{"schema":"CANARY-body"}`), withHeaders)                              // 422
	post(t, srv2, g, withHeaders)                                                               // 200
	post(t, srv2, g, func(r *http.Request) { r.Header.Set("X-HPL-Request-ID", "CANARY-body") }) // 400
	// A failed TLS handshake: net/http's own error text would include the client's address.
	conn, err := net.Dial("tcp", srv2.Listener.Addr().String())
	if err == nil {
		_, _ = conn.Write([]byte("GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
		_, _ = io.ReadAll(conn)
		conn.Close()
	}
	time.Sleep(100 * time.Millisecond)
	all := logs.String() + logs2.String()
	for _, c := range canaries {
		if strings.Contains(all, c) {
			t.Errorf("log contains %q:\n%s", c, all)
		}
	}
	if !strings.Contains(all, `"class":"attest"`) || !strings.Contains(all, `"class":"ok"`) || !strings.Contains(all, "http_server_error") {
		t.Errorf("expected outcome-only log lines:\n%s", all)
	}
}

type panicky struct{}

func (panicky) Analyze(context.Context, *api.Payload) (api.Insights, error) { panic("CANARY-panic") }

type slow struct{ release chan struct{} }

func (s slow) Analyze(ctx context.Context, p *api.Payload) (api.Insights, error) {
	<-s.release
	return api.RulesAnalyzer{}.Analyze(ctx, p)
}

type liar struct{}

func (liar) Analyze(context.Context, *api.Payload) (api.Insights, error) {
	return api.Insights{Schema: api.InsightsSchema, RequestID: "11111111-1111-4111-8111-111111111111"}, nil
}

type broken struct{}

func (broken) Analyze(context.Context, *api.Payload) (api.Insights, error) {
	return api.Insights{}, errors.New("CANARY-err")
}

func TestAnalyzerFailuresAreContained(t *testing.T) {
	for name, a := range map[string]api.Analyzer{"panic": panicky{}, "wrong id": liar{}, "error": broken{}} {
		srv, logs := newServer(t, Config{Analyzer: a})
		resp, b := post(t, srv, golden(t), nil)
		if resp.StatusCode < 500 || strings.Contains(string(b), "CANARY") || strings.Contains(logs.String(), "CANARY") {
			t.Errorf("%s: %d %s / %s", name, resp.StatusCode, b, logs.String())
		}
	}
}

func TestBusyWhenSaturated(t *testing.T) {
	s := slow{release: make(chan struct{})}
	srv, _ := newServer(t, Config{Analyzer: s, MaxInFlight: 1})
	done := make(chan int)
	go func() { r, _ := post(t, srv, golden(t), nil); done <- r.StatusCode }()
	time.Sleep(150 * time.Millisecond)
	if r, _ := post(t, srv, golden(t), nil); r.StatusCode != 503 {
		t.Errorf("second request %d, want 503", r.StatusCode)
	}
	close(s.release)
	if st := <-done; st != 200 {
		t.Errorf("first request %d", st)
	}
}

func TestAttestHookGetsBodyHash(t *testing.T) {
	var got [32]byte
	v := hookFunc(func(_ *http.Request, h [32]byte) error { got = h; return nil })
	srv, _ := newServer(t, Config{Attest: v})
	g := golden(t)
	if r, _ := post(t, srv, g, nil); r.StatusCode != 200 {
		t.Fatal(r.StatusCode)
	}
	if got != sha256.Sum256(g) {
		t.Fatal("hook did not receive SHA-256 of the exact body")
	}
}

type hookFunc func(*http.Request, [32]byte) error

func (f hookFunc) Verify(r *http.Request, h [32]byte) error { return f(r, h) }
func (hookFunc) Mode() string                               { return "test" }
