package spire

import (
	"context"
	"fmt"
	"strings"
	"time"

	entryv1 "github.com/spiffe/spire-api-sdk/proto/spire/api/server/entry/v1"
	"github.com/spiffe/spire-api-sdk/proto/spire/api/types"
)

type SPIREClient interface {
	Create(ctx context.Context, entry *types.Entry) (*types.Entry, error)
	Update(ctx context.Context, entry *types.Entry) (*types.Entry, error)
	ListBySpiffeID(ctx context.Context, spiffeID string) ([]*types.Entry, error)
	Delete(ctx context.Context, id string) error
}

type Client struct {
	entryClient entryv1.EntryClient
}

// NewAdmin is DEPRECATED. Use NewAdminTLS instead.
//
// Legacy single-node path using Unix socket. Fails if called.
// Phase A (multi-node hardening): This path is no longer supported.
//
// Deprecated: Use NewAdminTLS with TLS credentials for secure admin connection.
func NewAdmin(ctx context.Context, adminSocketPath string) (*Client, error) {
	return nil, fmt.Errorf(
		"Unix socket admin path no longer supported. Use NewAdminTLS with TLS credentials. " +
			"Set SPIRE_ADMIN_SERVER_ADDR=spire-server.spire-system.svc:8081 and provide TLS cert paths " +
			"(SPIRE_ADMIN_CLIENT_CERT, SPIRE_ADMIN_CLIENT_KEY, SPIRE_ADMIN_CA_CERT)",
	)
}

func (c *Client) Create(ctx context.Context, entry *types.Entry) (*types.Entry, error) {
	resp, err := c.entryClient.BatchCreateEntry(ctx, &entryv1.BatchCreateEntryRequest{
		Entries: []*types.Entry{entry},
	})
	if err != nil {
		return nil, err
	}
	if len(resp.Results) == 0 {
		return nil, fmt.Errorf("no result returned from batch create")
	}
	result := resp.Results[0]
	if result.Status.Code != 0 {
		return nil, fmt.Errorf("batch create failed: %s", result.Status.Message)
	}
	return result.Entry, nil
}

func (c *Client) Update(ctx context.Context, entry *types.Entry) (*types.Entry, error) {
	resp, err := c.entryClient.BatchUpdateEntry(ctx, &entryv1.BatchUpdateEntryRequest{
		Entries: []*types.Entry{entry},
	})
	if err != nil {
		return nil, err
	}
	if len(resp.Results) == 0 {
		return nil, fmt.Errorf("no result returned from batch update")
	}
	result := resp.Results[0]
	if result.Status.Code != 0 {
		return nil, fmt.Errorf("batch update failed: %s", result.Status.Message)
	}
	return result.Entry, nil
}

func (c *Client) ListBySpiffeID(ctx context.Context, spiffeID string) ([]*types.Entry, error) {
	parsedID := parseSPIFFEID(spiffeID)
	resp, err := c.entryClient.ListEntries(ctx, &entryv1.ListEntriesRequest{
		Filter: &entryv1.ListEntriesRequest_Filter{
			BySpiffeId: parsedID,
		},
	})
	if err != nil {
		return nil, err
	}
	return resp.Entries, nil
}

func (c *Client) Delete(ctx context.Context, id string) error {
	_, err := c.entryClient.BatchDeleteEntry(ctx, &entryv1.BatchDeleteEntryRequest{
		Ids: []string{id},
	})
	return err
}

func TimeoutContext(parent context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(parent, 10*time.Second)
}

func parseSPIFFEID(spiffeID string) *types.SPIFFEID {
	// SPIFFE ID format: spiffe://trustdomain/path
	if !strings.HasPrefix(spiffeID, "spiffe://") {
		return &types.SPIFFEID{TrustDomain: "", Path: spiffeID}
	}

	parts := strings.TrimPrefix(spiffeID, "spiffe://")
	slashIndex := strings.Index(parts, "/")
	if slashIndex == -1 {
		return &types.SPIFFEID{TrustDomain: parts, Path: ""}
	}

	return &types.SPIFFEID{
		TrustDomain: parts[:slashIndex],
		Path:        parts[slashIndex:],
	}
}
