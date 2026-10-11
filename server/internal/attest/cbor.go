package attest

import (
	"encoding/binary"
	"errors"
)

var errCBOR = errors.New("bad cbor")

// decodeAssertion reads the App Attest assertion: a CBOR map {"signature": bstr, "authenticatorData": bstr}.
// Only the CBOR subset that shape needs is supported (definite-length maps, text and byte strings).
func decodeAssertion(b []byte) (sig, authData []byte, err error) {
	d := cborReader{b: b}
	major, n, err := d.head()
	if err != nil || major != 5 || n > 8 {
		return nil, nil, errCBOR
	}
	for i := uint64(0); i < n; i++ {
		km, kn, err := d.head()
		if err != nil || km != 3 {
			return nil, nil, errCBOR
		}
		key, err := d.take(kn)
		if err != nil {
			return nil, nil, errCBOR
		}
		vm, vn, err := d.head()
		if err != nil || vm != 2 {
			return nil, nil, errCBOR
		}
		val, err := d.take(vn)
		if err != nil {
			return nil, nil, errCBOR
		}
		switch string(key) {
		case "signature":
			sig = val
		case "authenticatorData":
			authData = val
		}
	}
	if d.i != len(b) || sig == nil || authData == nil {
		return nil, nil, errCBOR
	}
	return sig, authData, nil
}

type cborReader struct {
	b []byte
	i int
}

func (r *cborReader) head() (major byte, n uint64, err error) {
	if r.i >= len(r.b) {
		return 0, 0, errCBOR
	}
	ib := r.b[r.i]
	r.i++
	major, info := ib>>5, ib&0x1f
	switch {
	case info < 24:
		return major, uint64(info), nil
	case info == 24:
		v, err := r.take(1)
		if err != nil {
			return 0, 0, err
		}
		return major, uint64(v[0]), nil
	case info == 25:
		v, err := r.take(2)
		if err != nil {
			return 0, 0, err
		}
		return major, uint64(binary.BigEndian.Uint16(v)), nil
	case info == 26:
		v, err := r.take(4)
		if err != nil {
			return 0, 0, err
		}
		return major, uint64(binary.BigEndian.Uint32(v)), nil
	default: // 8-byte lengths and indefinite lengths are never needed here
		return 0, 0, errCBOR
	}
}

func (r *cborReader) take(n uint64) ([]byte, error) {
	if n > uint64(len(r.b)-r.i) {
		return nil, errCBOR
	}
	v := r.b[r.i : r.i+int(n)]
	r.i += int(n)
	return v, nil
}
