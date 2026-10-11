// Package pin computes the public-key pins HTTPSCloudTransport checks on iOS:
// base64(SHA-256(SecKeyCopyExternalRepresentation(key))). That is NOT the SPKI (HPKP / openssl) pin: for EC keys the
// hashed bytes are the X9.63 uncompressed point (04 || X || Y); for RSA keys, the PKCS#1 RSAPublicKey DER.
package pin

import (
	"crypto/ecdsa"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
)

// ForPublicKey returns the iOS pin for an ECDSA or RSA public key.
func ForPublicKey(pub any) (string, error) {
	var raw []byte
	switch k := pub.(type) {
	case *ecdsa.PublicKey:
		ek, err := k.ECDH()
		if err != nil {
			return "", err
		}
		raw = ek.Bytes() // uncompressed point
	case *rsa.PublicKey:
		raw = x509.MarshalPKCS1PublicKey(k)
	default:
		return "", fmt.Errorf("unsupported key type %T (use ECDSA P-256/P-384 or RSA)", pub)
	}
	sum := sha256.Sum256(raw)
	return base64.StdEncoding.EncodeToString(sum[:]), nil
}

// ForPEMChain returns one pin per certificate in a PEM bundle, leaf first.
func ForPEMChain(pemBytes []byte) ([]string, error) {
	var pins []string
	for {
		var block *pem.Block
		block, pemBytes = pem.Decode(pemBytes)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, err
		}
		p, err := ForPublicKey(cert.PublicKey)
		if err != nil {
			return nil, err
		}
		pins = append(pins, p)
	}
	if len(pins) == 0 {
		return nil, errors.New("no certificates found")
	}
	return pins, nil
}
