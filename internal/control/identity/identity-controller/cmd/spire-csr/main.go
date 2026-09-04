package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"threadforge/controllers/identity/identity-controller/internal/spire"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
	securityv1 "istio.io/api/security/v1alpha1"
)

type spireCSRServer struct {
	securityv1.UnimplementedIstioCertificateServiceServer

	caSigner         *spire.LocalCASigner
	workloadSocket   string
	trustDomain      string
	defaultTTL       int32
	namespaceTTLs    map[string]int32
	trustSourceReady func(context.Context) error
}

func (s *spireCSRServer) CreateCertificate(ctx context.Context, req *securityv1.IstioCertificateRequest) (*securityv1.IstioCertificateResponse, error) {
	if req == nil || strings.TrimSpace(req.GetCsr()) == "" {
		log.Printf("CreateCertificate rejected: empty CSR")
		return nil, status.Error(codes.InvalidArgument, "CSR is required")
	}

	// Verify our own workload identity is healthy (liveness gate).
	if _, err := spire.FetchSVID(ctx, s.workloadSocket); err != nil {
		log.Printf("CreateCertificate rejected: workload API unavailable: %v", err)
		return nil, status.Errorf(codes.Unavailable, "SPIRE Workload API unavailable: %v", err)
	}
	if s.trustSourceReady != nil {
		if err := s.trustSourceReady(ctx); err != nil {
			log.Printf("CreateCertificate rejected: SPIRE trust source unavailable: %v", err)
			return nil, status.Errorf(codes.Unavailable, "SPIRE trust source unavailable: %v", err)
		}
	}

	csrDER, spiffeID, err := parseAndValidateCSR(req.GetCsr(), s.trustDomain)
	if err != nil {
		log.Printf("CreateCertificate rejected: CSR validation failed: %v", err)
		return nil, status.Errorf(codes.InvalidArgument, "invalid CSR: %v", err)
	}

	ttl := resolveTTL(spiffeID, s.trustDomain, s.defaultTTL, req.GetValidityDuration(), s.namespaceTTLs)

	// Sign the CSR using the locally configured CA certificate and key.
	// No SPIRE server API is involved.
	chainDER, err := s.caSigner.SignCSR(ctx, csrDER, ttl)
	if err != nil {
		log.Printf("CreateCertificate sign failed for %s: %v", spiffeID, err)
		return nil, status.Errorf(codes.Internal, "failed to sign certificate for %s: %v", spiffeID, err)
	}

	chainPEM := make([]string, 0, len(chainDER))
	seen := map[string]struct{}{}
	appendCert := func(p string) {
		if strings.TrimSpace(p) == "" {
			return
		}
		if _, ok := seen[p]; ok {
			return
		}
		seen[p] = struct{}{}
		chainPEM = append(chainPEM, p)
	}
	for _, certBytes := range chainDER {
		if len(certBytes) == 0 {
			continue
		}

		if block, _ := pem.Decode(certBytes); block != nil && block.Type == "CERTIFICATE" {
			appendCert(strings.TrimSpace(string(certBytes)) + "\n")
			continue
		}

		if _, parseErr := x509.ParseCertificate(certBytes); parseErr == nil {
			appendCert(string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certBytes})))
			continue
		}

		log.Printf("CreateCertificate warning for %s: dropping unparseable cert bytes in chain", spiffeID)
	}

	if len(chainPEM) == 0 {
		log.Printf("CreateCertificate failed for %s: signing returned no usable certs", spiffeID)
		return nil, status.Error(codes.Internal, "CA returned an empty cert chain")
	}

	log.Printf("CreateCertificate succeeded for %s ttl=%d chain_len=%d", spiffeID, ttl, len(chainPEM))
	return &securityv1.IstioCertificateResponse{CertChain: chainPEM}, nil
}

func parseAndValidateCSR(csrPEM string, trustDomain string) ([]byte, string, error) {
	block, _ := pem.Decode([]byte(csrPEM))
	if block == nil || len(block.Bytes) == 0 {
		return nil, "", fmt.Errorf("CSR PEM decode failed")
	}

	csr, err := x509.ParseCertificateRequest(block.Bytes)
	if err != nil {
		return nil, "", fmt.Errorf("failed to parse CSR DER: %w", err)
	}
	if err := csr.CheckSignature(); err != nil {
		return nil, "", fmt.Errorf("invalid CSR signature: %w", err)
	}

	if len(csr.URIs) != 1 {
		return nil, "", fmt.Errorf("CSR must contain exactly one URI SAN")
	}
	spiffeID := csr.URIs[0].String()
	prefix := "spiffe://" + trustDomain + "/"
	if !strings.HasPrefix(spiffeID, prefix) {
		return nil, "", fmt.Errorf("SPIFFE SAN %q does not match trust domain %q", spiffeID, trustDomain)
	}

	return block.Bytes, spiffeID, nil
}

func resolveTTL(spiffeID string, trustDomain string, defaultTTL int32, requestedTTL int64, namespaceTTLs map[string]int32) int32 {
	ttl := defaultTTL
	if requestedTTL > 0 {
		ttl = int32(requestedTTL)
	}

	namespace := namespaceFromSPIFFEID(spiffeID, trustDomain)
	if overrideTTL, ok := namespaceTTLs[namespace]; ok && overrideTTL > 0 {
		if ttl <= 0 || ttl > overrideTTL {
			return overrideTTL
		}
	}

	return ttl
}

func namespaceFromSPIFFEID(spiffeID string, trustDomain string) string {
	prefix := "spiffe://" + trustDomain + "/ns/"
	if !strings.HasPrefix(spiffeID, prefix) {
		return ""
	}
	remainder := strings.TrimPrefix(spiffeID, prefix)
	parts := strings.SplitN(remainder, "/", 3)
	if len(parts) < 2 || parts[0] == "" || parts[1] != "sa" {
		return ""
	}
	return parts[0]
}

func parseNamespaceTTLOverrides(raw string) (map[string]int32, error) {
	overrides := map[string]int32{}
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		namespace, ttlText, found := strings.Cut(part, "=")
		if !found {
			return nil, fmt.Errorf("invalid namespace TTL override %q", part)
		}
		namespace = strings.TrimSpace(namespace)
		ttlText = strings.TrimSpace(ttlText)
		if namespace == "" || ttlText == "" {
			return nil, fmt.Errorf("invalid namespace TTL override %q", part)
		}
		ttl, err := strconv.ParseInt(ttlText, 10, 32)
		if err != nil || ttl <= 0 {
			return nil, fmt.Errorf("invalid TTL %q for namespace %q", ttlText, namespace)
		}
		overrides[namespace] = int32(ttl)
	}
	return overrides, nil
}

type spireServerAvailabilityChecker struct {
	client        *http.Client
	apiURL        string
	namespace     string
	labelSelector string
	bearerToken   string
}

func newSpireServerAvailabilityChecker() (*spireServerAvailabilityChecker, error) {
	apiHost := strings.TrimSpace(os.Getenv("KUBERNETES_SERVICE_HOST"))
	if apiHost == "" {
		apiHost = "kubernetes.default.svc"
	}
	apiPort := strings.TrimSpace(os.Getenv("KUBERNETES_SERVICE_PORT_HTTPS"))
	if apiPort == "" {
		apiPort = strings.TrimSpace(os.Getenv("KUBERNETES_SERVICE_PORT"))
	}
	if apiPort == "" {
		apiPort = "443"
	}
	caPath := envOrDefault("SPIRE_CSR_KUBE_CA_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
	caPEM, err := os.ReadFile(caPath)
	if err != nil {
		return nil, fmt.Errorf("read Kubernetes CA: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("parse Kubernetes CA: no valid certificates")
	}
	tokenPath := envOrDefault("SPIRE_CSR_KUBE_TOKEN_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/token")
	tokenBytes, err := os.ReadFile(tokenPath)
	if err != nil {
		return nil, fmt.Errorf("read Kubernetes bearer token: %w", err)
	}
	token := strings.TrimSpace(string(tokenBytes))
	if token == "" {
		return nil, fmt.Errorf("read Kubernetes bearer token: empty token")
	}

	transport := &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
	}

	return &spireServerAvailabilityChecker{
		client: &http.Client{Transport: transport, Timeout: 5 * time.Second},
		apiURL: fmt.Sprintf("https://%s:%s", apiHost, apiPort),
		namespace: envOrDefault("SPIRE_CSR_SPIRE_SERVER_NAMESPACE", "spire-system"),
		labelSelector: envOrDefault("SPIRE_CSR_SPIRE_SERVER_LABEL_SELECTOR", "app=spire-server"),
		bearerToken: token,
	}, nil
}

func (c *spireServerAvailabilityChecker) Check(ctx context.Context) error {
	if c == nil {
		return nil
	}
	requestURL, err := buildPodsAPIURL(c.apiURL, c.namespace, c.labelSelector)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL, nil)
	if err != nil {
		return fmt.Errorf("build Kubernetes request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.bearerToken)
	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("query Kubernetes for SPIRE server pods: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("query Kubernetes for SPIRE server pods: unexpected status %s", resp.Status)
	}
	var doc struct {
		Items []json.RawMessage `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return fmt.Errorf("decode Kubernetes pod list: %w", err)
	}
	if len(doc.Items) == 0 {
		return fmt.Errorf("no running SPIRE server pods")
	}
	return nil
}

func buildPodsAPIURL(apiURL string, namespace string, labelSelector string) (string, error) {
	base, err := url.Parse(strings.TrimRight(apiURL, "/"))
	if err != nil {
		return "", fmt.Errorf("parse Kubernetes API URL: %w", err)
	}
	base.Path = fmt.Sprintf("/api/v1/namespaces/%s/pods", namespace)
	query := base.Query()
	query.Set("labelSelector", labelSelector)
	query.Set("fieldSelector", "status.phase=Running")
	base.RawQuery = query.Encode()
	return base.String(), nil
}

func fetchCurrentServingCert(ctx context.Context, workloadSocket string) (*tls.Certificate, error) {
	svid, err := workloadapi.FetchX509SVID(ctx, workloadapi.WithAddr(workloadSocket))
	if err != nil {
		return nil, fmt.Errorf("failed to fetch serving SVID from Workload API: %w", err)
	}
	if svid == nil || len(svid.Certificates) == 0 || svid.PrivateKey == nil {
		return nil, fmt.Errorf("SPIRE Workload API returned incomplete serving SVID")
	}

	chain := make([][]byte, 0, len(svid.Certificates)+2)
	seen := map[string]struct{}{}
	appendRawCert := func(raw []byte) {
		if len(raw) == 0 {
			return
		}
		key := string(raw)
		if _, ok := seen[key]; ok {
			return
		}
		seen[key] = struct{}{}
		chain = append(chain, raw)
	}
	for _, cert := range svid.Certificates {
		if cert == nil {
			continue
		}
		appendRawCert(cert.Raw)
	}

	bundleSet, bundleErr := workloadapi.FetchX509Bundles(ctx, workloadapi.WithAddr(workloadSocket))
	if bundleErr != nil {
		return nil, fmt.Errorf("failed to fetch serving trust bundle from Workload API: %w", bundleErr)
	}
	for _, bundle := range bundleSet.Bundles() {
		for _, authority := range bundle.X509Authorities() {
			if authority == nil {
				continue
			}
			appendRawCert(authority.Raw)
		}
	}
	if len(chain) == 0 {
		return nil, fmt.Errorf("SPIRE Workload API returned empty cert chain")
	}

	return &tls.Certificate{
		Certificate: chain,
		PrivateKey:  svid.PrivateKey,
		Leaf:        svid.Certificates[0],
	}, nil
}

func loadStaticServingCert(certFile string, keyFile string) (*tls.Certificate, error) {
	certPEM, err := os.ReadFile(certFile)
	if err != nil {
		return nil, fmt.Errorf("failed to read serving certificate from %s: %w", certFile, err)
	}
	keyPEM, err := os.ReadFile(keyFile)
	if err != nil {
		return nil, fmt.Errorf("failed to read serving private key from %s: %w", keyFile, err)
	}

	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, fmt.Errorf("failed to parse serving certificate/key pair: %w", err)
	}
	if len(pair.Certificate) == 0 {
		return nil, fmt.Errorf("serving certificate chain is empty")
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, fmt.Errorf("failed to parse serving leaf certificate: %w", err)
	}
	pair.Leaf = leaf
	return &pair, nil
}

func newServerTLSConfig(workloadSocket string, staticCert *tls.Certificate) *tls.Config {
	if staticCert != nil {
		return &tls.Config{
			MinVersion: tls.VersionTLS12,
			NextProtos: []string{"h2"},
			GetCertificate: func(_ *tls.ClientHelloInfo) (*tls.Certificate, error) {
				return staticCert, nil
			},
		}
	}

	return &tls.Config{
		MinVersion: tls.VersionTLS12,
		NextProtos: []string{"h2"},
		GetCertificate: func(_ *tls.ClientHelloInfo) (*tls.Certificate, error) {
			fetchCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			return fetchCurrentServingCert(fetchCtx, workloadSocket)
		},
	}
}

func workloadSocketPath(socketAddr string) string {
	trimmed := strings.TrimSpace(socketAddr)
	trimmed = strings.TrimPrefix(trimmed, "unix://")
	if trimmed == "" {
		return ""
	}
	if strings.HasPrefix(trimmed, "/") {
		return filepath.Clean(trimmed)
	}
	return filepath.Clean("/" + trimmed)
}

func runProbe() int {
	workloadSocket := envOrDefault("SPIFFE_ENDPOINT_SOCKET", "unix:///run/spire/sockets/agent.sock")
	socketPath := workloadSocketPath(workloadSocket)
	if socketPath == "" {
		log.Printf("probe failed: SPIFFE_ENDPOINT_SOCKET resolved to empty path")
		return 1
	}

	info, err := os.Stat(socketPath)
	if err != nil {
		log.Printf("probe failed: workload socket stat failed for %s: %v", socketPath, err)
		return 1
	}
	if info.Mode()&os.ModeSocket == 0 {
		log.Printf("probe failed: workload socket path is not a unix socket: %s", socketPath)
		return 1
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if _, err := spire.FetchSVID(ctx, workloadSocket); err != nil {
		log.Printf("probe failed: workload API unavailable via %s: %v", workloadSocket, err)
		return 1
	}

	return 0
}

func runWorkloadAPIGuard(workloadSocket string) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_, err := spire.FetchSVID(ctx, workloadSocket)
		cancel()
		if err != nil {
			log.Fatalf("SPIRE Workload API runtime guard failed: %v", err)
		}
	}
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "probe" {
		os.Exit(runProbe())
	}

	listenAddr := envOrDefault("SPIRE_CSR_LISTEN_ADDR", ":6443")
	workloadSocket := envOrDefault("SPIFFE_ENDPOINT_SOCKET", "unix:///run/spire/sockets/agent.sock")
	trustDomain := envOrDefault("SPIRE_TRUST_DOMAIN", "identity.threadforge.local")
	caCertFile := envOrDefault("SPIRE_CSR_CA_CERT_FILE", "/run/spire-csr/ca/ca.crt")
	caKeyFile := envOrDefault("SPIRE_CSR_CA_KEY_FILE", "/run/spire-csr/ca/ca.key")
	servingCertFile := strings.TrimSpace(os.Getenv("SPIRE_CSR_SERVING_CERT_FILE"))
	servingKeyFile := strings.TrimSpace(os.Getenv("SPIRE_CSR_SERVING_KEY_FILE"))
	namespaceTTLs, err := parseNamespaceTTLOverrides(os.Getenv("SPIRE_CSR_NAMESPACE_TTL_OVERRIDES"))
	if err != nil {
		log.Fatalf("failed to parse SPIRE_CSR_NAMESPACE_TTL_OVERRIDES: %v", err)
	}
	trustSourceChecker, err := newSpireServerAvailabilityChecker()
	if err != nil {
		log.Fatalf("failed to initialize SPIRE trust source checker: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	if _, err := spire.FetchSVID(ctx, workloadSocket); err != nil {
		log.Fatalf("SPIRE Workload API preflight failed: %v", err)
	}

	go runWorkloadAPIGuard(workloadSocket)

	caCertPEM, err := os.ReadFile(caCertFile)
	if err != nil {
		log.Fatalf("failed to read CA certificate from %s: %v", caCertFile, err)
	}
	caKeyPEM, err := os.ReadFile(caKeyFile)
	if err != nil {
		log.Fatalf("failed to read CA private key from %s: %v", caKeyFile, err)
	}

	caSigner, err := spire.NewLocalCASigner(caCertPEM, caKeyPEM)
	if err != nil {
		log.Fatalf("failed to initialize CA signer: %v", err)
	}

	var staticServingCert *tls.Certificate
	if servingCertFile != "" || servingKeyFile != "" {
		if servingCertFile == "" || servingKeyFile == "" {
			log.Fatalf("both SPIRE_CSR_SERVING_CERT_FILE and SPIRE_CSR_SERVING_KEY_FILE must be set together")
		}
		staticServingCert, err = loadStaticServingCert(servingCertFile, servingKeyFile)
		if err != nil {
			log.Fatalf("failed to load static serving certificate: %v", err)
		}
		log.Printf("using static serving certificate from %s", servingCertFile)
	} else {
		log.Printf("using SPIRE Workload API serving SVID")
	}

	tlsCfg := newServerTLSConfig(workloadSocket, staticServingCert)

	lis, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", listenAddr, err)
	}

	grpcServer := grpc.NewServer(grpc.Creds(credentials.NewTLS(tlsCfg)))
	securityv1.RegisterIstioCertificateServiceServer(grpcServer, &spireCSRServer{
		caSigner:       caSigner,
		workloadSocket: workloadSocket,
		trustDomain:    trustDomain,
		defaultTTL:     3600,
		namespaceTTLs:  namespaceTTLs,
		trustSourceReady: trustSourceChecker.Check,
	})

	log.Printf("spire-csr listening on %s (trust_domain=%s, ca_cert=%s)", listenAddr, trustDomain, caCertFile)
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("gRPC server exited: %v", err)
	}
}

func envOrDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}
