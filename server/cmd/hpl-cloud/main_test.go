package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testPair(t *testing.T) (certPEM, keyPEM string) {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "hpl.test"}, DNSNames: []string{"hpl.test"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	if err != nil {
		t.Fatal(err)
	}
	kd, err := x509.MarshalECPrivateKey(k)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})),
		string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kd}))
}

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestConfigureTLS(t *testing.T) {
	cert, key := testPair(t)
	dir := t.TempDir()
	cf, kf := filepath.Join(dir, "fullchain.pem"), filepath.Join(dir, "privkey.pem")
	if err := os.WriteFile(cf, []byte(cert), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(kf, []byte(key), 0o600); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name    string
		env     map[string]string
		on      bool
		wantErr string
	}{
		{"none", nil, false, ""},
		{"files", map[string]string{"HPL_TLS_CERT": cf, "HPL_TLS_KEY": kf}, true, ""},
		{"inline", map[string]string{"HPL_TLS_CERT_PEM": cert, "HPL_TLS_KEY_PEM": key}, true, ""},
		{"inline trimmed (secret stores drop trailing newline)", map[string]string{"HPL_TLS_CERT_PEM": strings.TrimSpace(cert), "HPL_TLS_KEY_PEM": strings.TrimSpace(key)}, true, ""},
		{"both", map[string]string{"HPL_TLS_CERT": cf, "HPL_TLS_KEY": kf, "HPL_TLS_CERT_PEM": cert, "HPL_TLS_KEY_PEM": key}, false, "not both"},
		{"half file pair", map[string]string{"HPL_TLS_CERT": cf}, false, "together"},
		{"half inline pair", map[string]string{"HPL_TLS_KEY_PEM": key}, false, "together"},
		{"garbage", map[string]string{"HPL_TLS_CERT_PEM": "x", "HPL_TLS_KEY_PEM": "y"}, false, "load TLS certificate"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := &tls.Config{}
			on, err := configureTLS(c, env(tc.env))
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("err = %v, want %q", err, tc.wantErr)
				}
				return
			}
			if err != nil || on != tc.on {
				t.Fatalf("on=%v err=%v, want on=%v", on, err, tc.on)
			}
			if on && len(c.Certificates) != 1 {
				t.Fatalf("certificates = %d", len(c.Certificates))
			}
		})
	}
}
