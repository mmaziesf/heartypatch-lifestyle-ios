package attest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"testing"
)

const appID = "ABCDE12345.com.hpl.lifestyle"

// cborAssertion builds {"signature": sig, "authenticatorData": ad} the way DCAppAttestService does.
func cborAssertion(sig, ad []byte) []byte {
	out := []byte{0xa2}
	str := func(major byte, b []byte) {
		switch n := len(b); {
		case n < 24:
			out = append(out, major<<5|byte(n))
		case n < 256:
			out = append(out, major<<5|24, byte(n))
		default:
			out = append(out, major<<5|25, byte(n>>8), byte(n))
		}
		out = append(out, b...)
	}
	str(3, []byte("signature"))
	str(2, sig)
	str(3, []byte("authenticatorData"))
	str(2, ad)
	return out
}

func assertion(t *testing.T, key *ecdsa.PrivateKey, rpID string, counter uint32, body []byte) []byte {
	t.Helper()
	rp := sha256.Sum256([]byte(rpID))
	ad := append(rp[:], 0x40)
	ad = binary.BigEndian.AppendUint32(ad, counter)
	cdh := sha256.Sum256(body)
	nonce := sha256.Sum256(append(append([]byte{}, ad...), cdh[:]...))
	digest := sha256.Sum256(nonce[:])
	sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return cborAssertion(sig, ad)
}

func setup(t *testing.T) (*ecdsa.PrivateKey, []byte, AppAttest) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	kid := []byte("key-id-1")
	ks := NewMemoryKeyStore()
	ks.Register(kid, &key.PublicKey)
	return key, kid, AppAttest{AppID: appID, Keys: ks}
}

func TestAssertionBindsBodyAndCounter(t *testing.T) {
	key, kid, a := setup(t)
	body := []byte(`{"schema":"hpl.cloud_payload.v1"}`)
	if err := a.verify(kid, assertion(t, key, appID, 1, body), sha256.Sum256(body)); err != nil {
		t.Fatalf("valid assertion refused: %v", err)
	}
	// Replay (same counter) and a lower counter fail.
	if err := a.verify(kid, assertion(t, key, appID, 1, body), sha256.Sum256(body)); !errors.Is(err, ErrRejected) {
		t.Fatal("replay accepted")
	}
	// Signed for a different body (user approved other bytes).
	if err := a.verify(kid, assertion(t, key, appID, 2, body), sha256.Sum256([]byte("other"))); !errors.Is(err, ErrRejected) {
		t.Fatal("body swap accepted")
	}
	// Different app id.
	if err := a.verify(kid, assertion(t, key, "OTHER.app", 3, body), sha256.Sum256(body)); !errors.Is(err, ErrRejected) {
		t.Fatal("wrong app id accepted")
	}
	// Unknown key and a key that signs with another private key.
	if err := a.verify([]byte("nope"), assertion(t, key, appID, 4, body), sha256.Sum256(body)); !errors.Is(err, ErrRejected) {
		t.Fatal("unknown key accepted")
	}
	other, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err := a.verify(kid, assertion(t, other, appID, 5, body), sha256.Sum256(body)); !errors.Is(err, ErrRejected) {
		t.Fatal("foreign signature accepted")
	}
	if err := a.verify(kid, assertion(t, key, appID, 6, body), sha256.Sum256(body)); err != nil {
		t.Fatalf("next counter refused: %v", err)
	}
}

func TestGarbageAssertions(t *testing.T) {
	_, kid, a := setup(t)
	for _, raw := range [][]byte{nil, {0xa2}, {0xff, 0x00}, cborAssertion(nil, []byte{1, 2}), append(cborAssertion([]byte{1}, []byte{2}), 0)} {
		if err := a.verify(kid, raw, [32]byte{}); err == nil {
			t.Fatalf("garbage accepted: %x", raw)
		}
	}
}

func FuzzDecodeAssertion(f *testing.F) {
	f.Add(cborAssertion([]byte{1, 2, 3}, make([]byte, 37)))
	f.Fuzz(func(t *testing.T, b []byte) { _, _, _ = decodeAssertion(b) })
}
