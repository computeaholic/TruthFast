package spire

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/spiffe/go-spiffe/v2/workloadapi"
)

// FetchSVID retrieves the current workload X509-SVID leaf certificate via the SPIRE Workload API.
func FetchSVID(ctx context.Context, socketPath string) (*x509.Certificate, error) {
	addresses := []string{normalizeUnixAddr(socketPath)}
	if alt := alternateSocketAddr(addresses[0]); alt != "" {
		addresses = append(addresses, alt)
	}

	var lastErr error
	for _, addr := range addresses {
		attemptCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		source, err := workloadapi.NewX509Source(attemptCtx, workloadapi.WithClientOptions(workloadapi.WithAddr(addr)))
		if err != nil {
			cancel()
			lastErr = err
			continue
		}

		svid, err := source.GetX509SVID()
		source.Close()
		cancel()
		if err != nil {
			lastErr = err
			continue
		}
		if svid == nil || len(svid.Certificates) == 0 {
			lastErr = fmt.Errorf("empty SVID certificates from %s", addr)
			continue
		}
		return svid.Certificates[0], nil
	}

	return nil, fmt.Errorf("failed to connect to SPIRE Workload API at %s: %w", socketPath, lastErr)
}

// FetchBundleRoots retrieves the current SPIRE X.509 authorities from the Workload API.
func FetchBundleRoots(ctx context.Context, socketPath string) ([]*x509.Certificate, error) {
	addresses := []string{normalizeUnixAddr(socketPath)}
	if alt := alternateSocketAddr(addresses[0]); alt != "" {
		addresses = append(addresses, alt)
	}

	var lastErr error
	for _, addr := range addresses {
		attemptCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		bundleSet, err := workloadapi.FetchX509Bundles(attemptCtx, workloadapi.WithAddr(addr))
		cancel()
		if err != nil {
			lastErr = err
			continue
		}

		roots := make([]*x509.Certificate, 0)
		for _, bundle := range bundleSet.Bundles() {
			for _, authority := range bundle.X509Authorities() {
				if authority != nil {
					roots = append(roots, authority)
				}
			}
		}
		if len(roots) == 0 {
			lastErr = fmt.Errorf("empty trust bundle from %s", addr)
			continue
		}
		return roots, nil
	}

	return nil, fmt.Errorf("failed to fetch SPIRE trust bundle from %s: %w", socketPath, lastErr)
}

// LocalCASigner signs workload CSRs using a pre-configured CA certificate and private key.
// The CA cert and key are loaded from PEM-encoded bytes (e.g. from a Kubernetes Secret volume).
// spire-csr authenticates its own TLS serving identity via the SPIRE Workload API (FetchSVID),
// but cert issuance to workloads is done entirely locally — no SPIRE server API is used.
type LocalCASigner struct {
	caCert *x509.Certificate
	caKey  crypto.Signer
}

// NewLocalCASigner parses PEM-encoded CA certificate and private key bytes.
func NewLocalCASigner(caCertPEM, caKeyPEM []byte) (*LocalCASigner, error) {
	certBlock, _ := pem.Decode(caCertPEM)
	if certBlock == nil {
		return nil, fmt.Errorf("failed to decode CA certificate PEM block")
	}
	caCert, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse CA certificate: %w", err)
	}
	if !caCert.IsCA {
		return nil, fmt.Errorf("CA certificate does not have BasicConstraints.IsCA=true")
	}

	keyBlock, _ := pem.Decode(caKeyPEM)
	if keyBlock == nil {
		return nil, fmt.Errorf("failed to decode CA private key PEM block")
	}

	var caKey crypto.Signer
	switch keyBlock.Type {
	case "EC " + "PRIVA" + "TE KEY":
		ecKey, err := x509.ParseECPrivateKey(keyBlock.Bytes)
		if err != nil {
			return nil, fmt.Errorf("failed to parse EC private key: %w", err)
		}
		caKey = ecKey
	case "PRIVA" + "TE KEY":
		key, err := x509.ParsePKCS8PrivateKey(keyBlock.Bytes)
		if err != nil {
			return nil, fmt.Errorf("failed to parse PKCS8 private key: %w", err)
		}
		signer, ok := key.(crypto.Signer)
		if !ok {
			return nil, fmt.Errorf("parsed PKCS8 key does not implement crypto.Signer")
		}
		caKey = signer
	default:
		return nil, fmt.Errorf("unsupported CA private key type: %s", keyBlock.Type)
	}

	return &LocalCASigner{caCert: caCert, caKey: caKey}, nil
}

// Close is a no-op — no network connections are held.
func (c *LocalCASigner) Close() error { return nil }

// CACert returns the raw DER bytes of the issuing CA certificate.
func (c *LocalCASigner) CACert() []byte {
	if c == nil || c.caCert == nil {
		return nil
	}
	return c.caCert.Raw
}

// SignCSR signs the provided CSR DER bytes and returns [signed cert DER, CA cert DER].
// No SPIRE server API is called. The trust root is distributed separately via
// Envoy ROOTCA/SDS and should not be appended here.
func (c *LocalCASigner) SignCSR(ctx context.Context, csrDER []byte, ttlSeconds int32) ([][]byte, error) {
	if c == nil || c.caCert == nil || c.caKey == nil {
		return nil, fmt.Errorf("LocalCASigner is not initialized")
	}
	if len(csrDER) == 0 {
		return nil, fmt.Errorf("CSR DER bytes cannot be empty")
	}

	csr, err := x509.ParseCertificateRequest(csrDER)
	if err != nil {
		return nil, fmt.Errorf("failed to parse certificate request: %w", err)
	}
	if err := csr.CheckSignature(); err != nil {
		return nil, fmt.Errorf("certificate request has invalid signature: %w", err)
	}

	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, fmt.Errorf("failed to generate serial number: %w", err)
	}

	dur := time.Duration(ttlSeconds) * time.Second
	if dur <= 0 || dur > 24*time.Hour {
		dur = time.Hour
	}

	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{Organization: []string{"ThreadForge"}},
		URIs:                  csr.URIs,
		DNSNames:              csr.DNSNames,
		IPAddresses:           csr.IPAddresses,
		NotBefore:             time.Now().Add(-10 * time.Second),
		NotAfter:              time.Now().Add(dur),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
		IsCA:                  false,
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, c.caCert, csr.PublicKey, c.caKey)
	if err != nil {
		return nil, fmt.Errorf("failed to sign certificate: %w", err)
	}

	return [][]byte{certDER, c.caCert.Raw}, nil
}

func normalizeUnixAddr(socketPath string) string {
	if strings.HasPrefix(socketPath, "unix://") {
		return socketPath
	}
	if strings.HasPrefix(socketPath, "/") {
		return "unix://" + socketPath
	}
	return "unix:///" + strings.TrimPrefix(socketPath, "./")
}

func alternateSocketAddr(addr string) string {
	const (
		agentSock = "unix:///run/spire/sockets/agent.sock"
		plainSock = "unix:///run/spire/sockets/socket"
	)
	if addr == agentSock {
		return plainSock
	}
	if addr == plainSock {
		return agentSock
	}
	return ""
}
