package spire

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"fmt"
	"log"
	"os"

	entryv1 "github.com/spiffe/spire-api-sdk/proto/spire/api/server/entry/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

// TLSClientConfig holds TLS credential paths for SPIRE admin API.
type TLSClientConfig struct {
	ClientCertFile    string // path to client certificate PEM
	ClientKeyFile     string // path to client private key PEM
	CACertFile        string // path to CA certificate PEM
	ServerName        string // expected server name for hostname validation
	PinnedFingerprint string // Phase A.2: optional SHA-256 fingerprint for cert pinning (hex-encoded)
}

// NewTLSDialCredentials constructs secure TLS credentials for SPIRE admin gRPC dial.
// Enforces:
//   - TLS 1.2 minimum
//   - Certificate verification (no InsecureSkipVerify)
//   - Proper ServerName for hostname validation
//   - Client certificate authentication
//
// Fails closed if any credential file is missing or invalid.
func (tc *TLSClientConfig) NewTLSDialCredentials() (credentials.TransportCredentials, error) {
	// Load client certificate and key
	clientCert, err := tls.LoadX509KeyPair(tc.ClientCertFile, tc.ClientKeyFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load client cert/key (%s, %s): %w", tc.ClientCertFile, tc.ClientKeyFile, err)
	}

	// Load CA certificate
	caCertPEM, err := os.ReadFile(tc.CACertFile)
	if err != nil {
		return nil, fmt.Errorf("failed to read CA certificate (%s): %w", tc.CACertFile, err)
	}

	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCertPEM) {
		return nil, fmt.Errorf("failed to parse CA certificate (%s)", tc.CACertFile)
	}

	// Construct TLS config
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{clientCert},
		RootCAs:      caCertPool,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		MinVersion:   tls.VersionTLS12,
		ServerName:   tc.ServerName,
		// InsecureSkipVerify MUST remain false (fail-closed)
		InsecureSkipVerify: false,
	}

	// Phase A.2: Certificate pinning (optional, enabled via SPIRE_ADMIN_CERT_FINGERPRINT)
	if tc.PinnedFingerprint != "" {
		tlsConfig.VerifyPeerCertificate = func(rawCerts [][]byte, verifiedChains [][]*x509.Certificate) error {
			// Compute SHA-256 fingerprint of server certificate
			if len(rawCerts) == 0 {
				return fmt.Errorf("no peer certificates presented")
			}

			serverCertFingerprint := sha256.Sum256(rawCerts[0])
			actualFingerprint := hex.EncodeToString(serverCertFingerprint[:])

			// Compare to pinned fingerprint
			if actualFingerprint != tc.PinnedFingerprint {
				// Phase A.2: Log mismatch event (no cert contents)
				log.Printf(
					"[SECURITY] Certificate pinning validation FAILED | "+
						"expected=%s | actual=%s | server=%s",
					tc.PinnedFingerprint,
					actualFingerprint,
					tc.ServerName,
				)
				return fmt.Errorf(
					"certificate fingerprint mismatch: expected %s, got %s (certificate pinning violation)",
					tc.PinnedFingerprint,
					actualFingerprint,
				)
			}

			// Fingerprint matched - log success
			log.Printf(
				"[SECURITY] Certificate pinning validation PASSED | fingerprint=%s | server=%s",
				tc.PinnedFingerprint,
				tc.ServerName,
			)

			return nil
		}
	}

	return credentials.NewTLS(tlsConfig), nil
}

// NewAdminTLS creates a SPIRE admin API client using TLS-secured TCP endpoint.
//
// Security posture:
//   - Requires valid client certificate + CA bundle
//   - TLS 1.2 minimum enforcement
//   - Hostname verification required
//   - No fallback to insecure connections
//   - Fails closed if credentials missing or invalid
//
// Multi-node ready: Yes
// Single-node compatible: Yes (if TLS certs provided)
//
// Parameters:
//
//	adminServerAddr: SPIRE admin gRPC server address (e.g., "spire-server.spire-system.svc:8081")
//	tlsConfig: TLS credential paths
//
// Returns: authenticated SPIRE admin client or error
func NewAdminTLS(adminServerAddr string, tlsConfig *TLSClientConfig) (*Client, error) {
	if adminServerAddr == "" {
		return nil, fmt.Errorf("admin server address required (e.g., spire-server.spire-system.svc:8081)")
	}
	if tlsConfig == nil {
		return nil, fmt.Errorf("TLS config required for secure admin connection")
	}

	// Construct TLS credentials
	creds, err := tlsConfig.NewTLSDialCredentials()
	if err != nil {
		return nil, fmt.Errorf("failed to construct TLS credentials: %w", err)
	}

	// Dial with TLS credentials
	conn, err := grpc.Dial(
		adminServerAddr,
		grpc.WithTransportCredentials(creds),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to dial SPIRE admin server (%s): %w", adminServerAddr, err)
	}

	// Phase A.1: Audit log for admin API connection
	logAdminConnection(adminServerAddr, tlsConfig)

	return &Client{
		entryClient: entryv1.NewEntryClient(conn),
	}, nil
}

// logAdminConnection emits audit log for SPIRE admin API connection.
//
// Phase A.1 requirement: Make admin-plane activity observable.
// No sensitive material logged (no credentials, only metadata).
func logAdminConnection(adminServerAddr string, tlsConfig *TLSClientConfig) {
	// Extract client cert subject (for audit trail)
	certSubject := "unknown"
	if tlsConfig.ClientCertFile != "" {
		// Load cert to extract subject (best effort, don't fail on error)
		certPEM, err := os.ReadFile(tlsConfig.ClientCertFile)
		if err == nil {
			cert, err := x509.ParseCertificate(certPEM)
			if err == nil && cert != nil {
				certSubject = cert.Subject.String()
			}
		}
	}

	// Get multi-node mode state (for context)
	multiNodeMode := os.Getenv("MULTI_NODE_MODE")
	if multiNodeMode == "" {
		multiNodeMode = "false"
	}

	// Structured log output (can be ingested by log aggregator)
	log.Printf(
		"[AUDIT] SPIRE Admin TLS Connection Established | "+
			"server=%s | "+
			"client_cert_subject=%s | "+
			"server_name=%s | "+
			"multi_node_mode=%s",
		adminServerAddr,
		certSubject,
		tlsConfig.ServerName,
		multiNodeMode,
	)
}
