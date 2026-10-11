// hpl-cloud is the stateless analysis endpoint for HP Lifestyle (docs/m8-cloud-endpoint.md).
//
//	hpl-cloud serve            serve HTTPS (or plain HTTP behind a TLS-passthrough proxy, see doc)
//	hpl-cloud pin cert.pem     print the iOS public-key pins for each certificate in a PEM chain
//
// Configuration is environment only:
//
//	HPL_ADDR            listen address (default :8443)
//	HPL_TLS_CERT/KEY    PEM files; when set, the server terminates TLS itself (TLS 1.3 only) — the pinned setup
//	HPL_PLAINTEXT=1     allow plain HTTP (local dev or a TLS-passthrough sidecar only; refused without it)
//	HPL_ATTEST          off (default) | app-attest
//	HPL_APP_ID          TEAMID.com.hpl.lifestyle (app-attest)
//	HPL_MAX_INFLIGHT    concurrent analyses (default 32)
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/mmaziesf/heartypatch-lifestyle-ios/server/internal/api"
	"github.com/mmaziesf/heartypatch-lifestyle-ios/server/internal/attest"
	"github.com/mmaziesf/heartypatch-lifestyle-ios/server/internal/pin"
	"github.com/mmaziesf/heartypatch-lifestyle-ios/server/internal/server"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "serve":
		if err := serve(); err != nil {
			fmt.Fprintln(os.Stderr, "hpl-cloud:", err)
			os.Exit(1)
		}
	case "pin":
		if len(os.Args) != 3 {
			usage()
		}
		b, err := os.ReadFile(os.Args[2])
		if err == nil {
			var pins []string
			if pins, err = pin.ForPEMChain(b); err == nil {
				for i, p := range pins {
					fmt.Printf("%d %s\n", i, p)
				}
				return
			}
		}
		fmt.Fprintln(os.Stderr, "hpl-cloud pin:", err)
		os.Exit(1)
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: hpl-cloud serve | hpl-cloud pin <cert-chain.pem>")
	os.Exit(2)
}

func serve() error {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	verifier, err := verifierFromEnv()
	if err != nil {
		return err
	}
	maxInFlight, _ := strconv.Atoi(os.Getenv("HPL_MAX_INFLIGHT"))
	h := server.New(server.Config{Analyzer: api.RulesAnalyzer{}, Attest: verifier, Logger: logger, MaxInFlight: maxInFlight})
	addr := envOr("HPL_ADDR", ":8443")
	srv := &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    8 << 10,
		ErrorLog:          server.SilentErrorLog(logger),
		TLSConfig:         server.TLSConfig(),
	}
	cert, key := os.Getenv("HPL_TLS_CERT"), os.Getenv("HPL_TLS_KEY")
	tlsOn := cert != "" && key != ""
	if !tlsOn && os.Getenv("HPL_PLAINTEXT") != "1" {
		return errors.New("set HPL_TLS_CERT and HPL_TLS_KEY (or HPL_PLAINTEXT=1 for local dev / TLS passthrough sidecar)")
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	errc := make(chan error, 1)
	go func() {
		logger.Info("listening", slog.String("addr", addr), slog.Bool("tls", tlsOn), slog.String("attest", verifier.Mode()))
		if tlsOn {
			errc <- srv.ListenAndServeTLS(cert, key)
		} else {
			errc <- srv.ListenAndServe()
		}
	}()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return srv.Shutdown(shutdown)
	}
}

func verifierFromEnv() (attest.Verifier, error) {
	switch envOr("HPL_ATTEST", "off") {
	case "off":
		return attest.Off{}, nil
	case "app-attest":
		appID := os.Getenv("HPL_APP_ID")
		if appID == "" {
			return nil, errors.New("HPL_ATTEST=app-attest needs HPL_APP_ID (TEAMID.bundle-id)")
		}
		// Registration (attestation verification) is not implemented yet, so this store starts empty and every
		// request is refused until keys are registered. See docs/m8-cloud-endpoint.md "Deploy gaps".
		return attest.AppAttest{AppID: appID, Keys: attest.NewMemoryKeyStore()}, nil
	default:
		return nil, errors.New("HPL_ATTEST must be off or app-attest")
	}
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
