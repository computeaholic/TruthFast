package hash

import (
	"crypto/sha3"
	"encoding/hex"
)

// SHA3512Hex returns a hex-encoded SHA3-512 hash of input.
// This is used for deterministic Kubernetes object naming
// derived from SPIFFE IDs.
func SHA3512Hex(input string) string {
	sum := sha3.Sum512([]byte(input))
	return hex.EncodeToString(sum[:])
}
