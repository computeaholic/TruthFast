package diff

import (
	"github.com/spiffe/spire-api-sdk/proto/spire/api/types"
)

func Equal(a, b *types.Entry) bool {
	if a == nil || b == nil {
		return false
	}

	if !spiffeIDEqual(a.SpiffeId, b.SpiffeId) {
		return false
	}
	if !spiffeIDEqual(a.ParentId, b.ParentId) {
		return false
	}
	if a.X509SvidTtl != b.X509SvidTtl {
		return false
	}

	return selectorsEqual(a.Selectors, b.Selectors)
}

func spiffeIDEqual(a, b *types.SPIFFEID) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.TrustDomain == b.TrustDomain && a.Path == b.Path
}

func selectorsEqual(a, b []*types.Selector) bool {
	if len(a) != len(b) {
		return false
	}

	seen := make(map[string]struct{}, len(a))
	for _, s := range a {
		seen[s.Type+":"+s.Value] = struct{}{}
	}
	for _, s := range b {
		if _, ok := seen[s.Type+":"+s.Value]; !ok {
			return false
		}
	}
	return true
}
