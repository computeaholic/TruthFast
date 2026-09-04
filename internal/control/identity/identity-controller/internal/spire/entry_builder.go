package spire

import (
	"threadforge/controllers/identity/identity-controller/api/v1"
	"github.com/spiffe/spire-api-sdk/proto/spire/api/types"
)

func EntryFromSpec(reg *v1.IdentityRegistration) *types.Entry {

	selectors := make([]*types.Selector, 0, len(reg.Spec.Selectors))
	for _, s := range reg.Spec.Selectors {
		selectors = append(selectors, &types.Selector{
			Type:  s.Type,
			Value: s.Value,
		})
	}

	entry := &types.Entry{
		SpiffeId:  parseSPIFFEID(reg.Spec.SpiffeID),
		ParentId:  parseSPIFFEID(reg.Spec.ParentID),
		Selectors: selectors,
	}

	if reg.Spec.TTL != nil {
		entry.X509SvidTtl = *reg.Spec.TTL
	}

	return entry
}