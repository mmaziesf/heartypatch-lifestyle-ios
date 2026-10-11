package pin

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// The pin must be over the X9.63 point (what SecKeyCopyExternalRepresentation returns on iOS), not the SPKI DER.
func TestECPinIsX963Point(t *testing.T) {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	raw := make([]byte, 65)
	raw[0] = 4
	k.X.FillBytes(raw[1:33])
	k.Y.FillBytes(raw[33:])
	want := sha256.Sum256(raw)
	got, err := ForPublicKey(&k.PublicKey)
	if err != nil || got != base64.StdEncoding.EncodeToString(want[:]) {
		t.Fatalf("pin %s err %v", got, err)
	}
	spki, _ := x509.MarshalPKIXPublicKey(&k.PublicKey)
	s := sha256.Sum256(spki)
	if got == base64.StdEncoding.EncodeToString(s[:]) {
		t.Fatal("pin must not be the SPKI hash")
	}
}

func TestRSAPinIsPKCS1(t *testing.T) {
	k, _ := rsa.GenerateKey(rand.Reader, 2048)
	want := sha256.Sum256(x509.MarshalPKCS1PublicKey(&k.PublicKey))
	if got, _ := ForPublicKey(&k.PublicKey); got != base64.StdEncoding.EncodeToString(want[:]) {
		t.Fatal("rsa pin mismatch")
	}
}

// A pinning client (same rule as HTTPSCloudTransport) accepts the server whose leaf key matches and refuses others.
func TestPinnedTLS13Client(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "127.0.0.1"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), DNSNames: []string{"localhost"}}
	der, _ := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	pemCert := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	pins, err := ForPEMChain(pemCert)
	if err != nil || len(pins) != 1 {
		t.Fatal(err)
	}
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) }))
	srv.TLS = &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}
	srv.StartTLS()
	defer srv.Close()

	client := func(pin string) *http.Client {
		return &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{
			MinVersion:         tls.VersionTLS13,
			InsecureSkipVerify: true, // self-signed test cert; the pin check below is the trust decision
			VerifyConnection: func(cs tls.ConnectionState) error {
				for _, c := range cs.PeerCertificates {
					if p, _ := ForPublicKey(c.PublicKey); p == pin {
						return nil
					}
				}
				return x509.UnknownAuthorityError{}
			},
		}}}
	}
	if resp, err := client(pins[0]).Get(srv.URL); err != nil {
		t.Fatalf("pinned client refused: %v", err)
	} else {
		resp.Body.Close()
		if resp.TLS.Version != tls.VersionTLS13 {
			t.Fatal("not TLS 1.3")
		}
	}
	if _, err := client("AAAA").Get(srv.URL); err == nil {
		t.Fatal("wrong pin accepted")
	}
}
