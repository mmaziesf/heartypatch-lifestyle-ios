// Package attest is the App Attest hook for POST /v1/analyze.
//
// The client signs the exact request body: clientDataHash = SHA-256(body), which is also the SHA-256 the user approved
// on the preview screen. The server verifies an App Attest *assertion* (Apple, "Validating apps that connect to your
// server", steps for assertions) against a previously registered key.
//
// Privacy trade-off (docs/m8-cloud-endpoint.md): an App Attest key id is stable per app install, so requiring
// assertions makes requests from one install linkable at the server even though the payload has no identity. The
// server never logs key ids, and the KeyStore keeps only {key id -> public key, counter}. Registration (verifying the
// attestation object and its certificate chain to Apple's App Attestation root) is NOT implemented here; see the doc.
package attest

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"net/http"
	"sync"
)

// Header names. The client sets both or neither.
const (
	HeaderKeyID     = "X-HPL-Attest-Key-ID"
	HeaderAssertion = "X-HPL-Attest-Assertion"
)

var (
	ErrMissing  = errors.New("attestation required")
	ErrRejected = errors.New("attestation rejected")
)

// Verifier is called with the SHA-256 of the exact request body before the payload is parsed.
type Verifier interface {
	Verify(r *http.Request, bodySHA256 [32]byte) error
	Mode() string
}

// Off accepts every request. Development and the synthetic-fixture demo only.
type Off struct{}

func (Off) Verify(*http.Request, [32]byte) error { return nil }
func (Off) Mode() string                         { return "off" }

// KeyStore holds registered App Attest public keys and their sign counters. It is the only server state App Attest
// needs; implementations must not store anything else about the request.
type KeyStore interface {
	// Lookup returns the key and the last accepted counter.
	Lookup(keyID []byte) (*ecdsa.PublicKey, uint32, bool)
	// Advance stores counter if it is greater than the stored one and reports whether it did (atomic per key).
	Advance(keyID []byte, counter uint32) bool
}

// AppAttest verifies assertions for one app id ("TEAMID.com.hpl.lifestyle").
type AppAttest struct {
	AppID string
	Keys  KeyStore
}

func (a AppAttest) Mode() string { return "app-attest" }

func (a AppAttest) Verify(r *http.Request, bodySHA256 [32]byte) error {
	kid, aerr := base64.StdEncoding.DecodeString(r.Header.Get(HeaderKeyID))
	raw, berr := base64.StdEncoding.DecodeString(r.Header.Get(HeaderAssertion))
	if aerr != nil || berr != nil || len(kid) == 0 || len(raw) == 0 {
		return ErrMissing
	}
	return a.verify(kid, raw, bodySHA256)
}

func (a AppAttest) verify(keyID, rawAssertion []byte, clientDataHash [32]byte) error {
	sig, authData, err := decodeAssertion(rawAssertion)
	if err != nil {
		return ErrRejected
	}
	pub, last, ok := a.Keys.Lookup(keyID)
	if !ok || len(authData) < 37 {
		return ErrRejected
	}
	// 1-3. nonce = SHA256(authenticatorData || clientDataHash); signature is ECDSA P-256 over SHA256(nonce).
	nonce := sha256.Sum256(append(append([]byte{}, authData...), clientDataHash[:]...))
	digest := sha256.Sum256(nonce[:])
	if !ecdsa.VerifyASN1(pub, digest[:], sig) {
		return ErrRejected
	}
	// 4. RP ID hash is SHA256(app id).
	rp := sha256.Sum256([]byte(a.AppID))
	if !bytes.Equal(authData[:32], rp[:]) {
		return ErrRejected
	}
	// 5. Counter strictly increases (replay protection).
	counter := binary.BigEndian.Uint32(authData[33:37])
	if counter <= last || !a.Keys.Advance(keyID, counter) {
		return ErrRejected
	}
	return nil
}

// MemoryKeyStore is for tests and single-instance deployments.
type MemoryKeyStore struct {
	mu   sync.Mutex
	keys map[string]*memKey
}

type memKey struct {
	pub     *ecdsa.PublicKey
	counter uint32
}

func NewMemoryKeyStore() *MemoryKeyStore { return &MemoryKeyStore{keys: map[string]*memKey{}} }

// Register adds a key that was attested out of band.
func (m *MemoryKeyStore) Register(keyID []byte, pub *ecdsa.PublicKey) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.keys[string(keyID)] = &memKey{pub: pub}
}

func (m *MemoryKeyStore) Lookup(keyID []byte) (*ecdsa.PublicKey, uint32, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	k, ok := m.keys[string(keyID)]
	if !ok {
		return nil, 0, false
	}
	return k.pub, k.counter, true
}

func (m *MemoryKeyStore) Advance(keyID []byte, counter uint32) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	k, ok := m.keys[string(keyID)]
	if !ok || counter <= k.counter {
		return false
	}
	k.counter = counter
	return true
}
