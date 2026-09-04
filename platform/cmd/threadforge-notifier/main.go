package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"maps"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type notifierEvent struct {
	Type          string         `json:"type,omitempty"`
	App           string         `json:"app,omitempty"`
	Status        string         `json:"status,omitempty"`
	Message       string         `json:"message,omitempty"`
	Timestamp     string         `json:"timestamp,omitempty"`
	RunID         string         `json:"run_id,omitempty"`
	Phase         string         `json:"phase,omitempty"`
	Final         string         `json:"final,omitempty"`
	FailClass     string         `json:"fail_class,omitempty"`
	StrictMode    *bool          `json:"strict_mode,omitempty"`
	AdvisoryCount *int           `json:"advisory_count,omitempty"`
	Details       map[string]any `json:"details,omitempty"`
}

type kubernetesEvent struct {
	Metadata struct {
		UID               string `json:"uid"`
		ResourceVersion   string `json:"resourceVersion"`
		CreationTimestamp string `json:"creationTimestamp"`
	} `json:"metadata"`
	Type               string `json:"type"`
	Reason             string `json:"reason"`
	Message            string `json:"message"`
	ReportingComponent string `json:"reportingComponent"`
	Source             struct {
		Component string `json:"component"`
	} `json:"source"`
	InvolvedObject struct {
		Kind      string `json:"kind"`
		Namespace string `json:"namespace"`
		Name      string `json:"name"`
	} `json:"involvedObject"`
}

type metricsStore struct {
	mu                 sync.RWMutex
	notificationTotals map[string]uint64
	forwardFailures    uint64
	proofRunsTotal     uint64
	proofFailuresTotal uint64
	phaseFailures      map[string]uint64
	lastEvent          string
}

func newMetricsStore() *metricsStore {
	return &metricsStore{
		notificationTotals: map[string]uint64{},
		phaseFailures:      map[string]uint64{},
	}
}

func (m *metricsStore) recordNotification(status string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.notificationTotals[status]++
	m.lastEvent = time.Now().UTC().Format(time.RFC3339)
}

func (m *metricsStore) recordForwardFailure() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.forwardFailures++
	m.lastEvent = time.Now().UTC().Format(time.RFC3339)
}

func (m *metricsStore) recordProofRun(failed bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.proofRunsTotal++
	if failed {
		m.proofFailuresTotal++
	}
	m.lastEvent = time.Now().UTC().Format(time.RFC3339)
}

func (m *metricsStore) recordPhaseFailure(phase string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.phaseFailures[phase]++
	m.lastEvent = time.Now().UTC().Format(time.RFC3339)
}

func (m *metricsStore) snapshot() (map[string]uint64, uint64, uint64, uint64, map[string]uint64, string) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	notificationTotals := map[string]uint64{}
	phaseFailures := map[string]uint64{}
	maps.Copy(notificationTotals, m.notificationTotals)
	maps.Copy(phaseFailures, m.phaseFailures)
	return notificationTotals, m.forwardFailures, m.proofRunsTotal, m.proofFailuresTotal, phaseFailures, m.lastEvent
}

type runtimeState struct {
	mu                       sync.Mutex
	proofRunsSeen            map[string]struct{}
	proofPhaseFailuresSeen   map[string]struct{}
	remediationAttemptsByRun map[string]int
	lastRemediationByHash    map[string]time.Time
}

func newRuntimeState() *runtimeState {
	return &runtimeState{
		proofRunsSeen:            map[string]struct{}{},
		proofPhaseFailuresSeen:   map[string]struct{}{},
		remediationAttemptsByRun: map[string]int{},
		lastRemediationByHash:    map[string]time.Time{},
	}
}

type remediationDecision struct {
	ShouldRun bool
	Reason    string
	Hash      string
}

type notifierServer struct {
	webhookURL             string
	failWebhookURL         string
	notifierSpiffeID       string
	notifierRole           string
	notifierNamespace      string
	httpClient             *http.Client
	metrics                *metricsStore
	kubeClient             *http.Client
	kubeAPIBase            string
	kubeToken              string
	watchNamespace         string
	pollInterval           time.Duration
	logger                 *log.Logger
	seenEvents             sync.Map
	eventLogPath           string
	remediationLogPath     string
	remediationCmd         string
	remediationTimeout     time.Duration
	remediationCooldown    time.Duration
	remediationMaxAttempts int
	state                  *runtimeState
	fileMu                 sync.Mutex
}

func main() {
	logger := log.New(os.Stdout, "", 0)
	webhookURL := strings.TrimSpace(os.Getenv("NOTIFIER_WEBHOOK_URL"))
	failWebhookURL := strings.TrimSpace(os.Getenv("NOTIFIER_FAIL_WEBHOOK_URL"))
	notifierSpiffeID := strings.TrimSpace(envOrDefault("NOTIFIER_SPIFFE_ID", "spiffe://identity.threadforge.local/ns/threadforge-system/sa/threadforge-notifier"))
	watchNamespace := envOrDefault("NOTIFIER_WATCH_NAMESPACE", "argocd")
	pollInterval := envDurationOrDefault("NOTIFIER_POLL_INTERVAL", 15*time.Second)
	eventLogPath := envOrDefault("NOTIFIER_EVENT_LOG_PATH", "/var/lib/threadforge-notifier/events/notifier_events.jsonl")
	remediationLogPath := envOrDefault("NOTIFIER_REMEDIATION_LOG_PATH", "/var/lib/threadforge-notifier/events/remediation.log")
	remediationCmd := strings.TrimSpace(os.Getenv("NOTIFIER_REMEDIATION_CMD"))
	remediationTimeout := envDurationOrDefault("NOTIFIER_REMEDIATION_TIMEOUT", 30*time.Second)
	remediationCooldown := envDurationOrDefault("NOTIFIER_REMEDIATION_COOLDOWN", 60*time.Second)
	remediationMaxAttempts := envIntOrDefault("NOTIFIER_MAX_REMEDIATION_ATTEMPTS", 1)

	kubeAPIBase, kubeToken, kubeTLSConfig, err := discoverInClusterConfig()
	if err != nil {
		logger.Fatalf("failed to initialize in-cluster notifier config: %v", err)
	}

	notifierRole, err := resolveNotifierRole(notifierSpiffeID)
	if err != nil {
		logger.Fatalf("failed to resolve notifier role: %v", err)
	}
	notifierNamespace, err := extractNamespaceFromSPIFFE(notifierSpiffeID)
	if err != nil {
		logger.Fatalf("failed to extract notifier namespace: %v", err)
	}

	server := &notifierServer{
		webhookURL:             webhookURL,
		failWebhookURL:         failWebhookURL,
		notifierSpiffeID:       notifierSpiffeID,
		notifierRole:           notifierRole,
		notifierNamespace:      notifierNamespace,
		httpClient:             &http.Client{Timeout: 10 * time.Second},
		metrics:                newMetricsStore(),
		kubeClient:             &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{TLSClientConfig: kubeTLSConfig}},
		kubeAPIBase:            kubeAPIBase,
		kubeToken:              kubeToken,
		watchNamespace:         watchNamespace,
		pollInterval:           pollInterval,
		logger:                 logger,
		eventLogPath:           eventLogPath,
		remediationLogPath:     remediationLogPath,
		remediationCmd:         remediationCmd,
		remediationTimeout:     remediationTimeout,
		remediationCooldown:    remediationCooldown,
		remediationMaxAttempts: remediationMaxAttempts,
		state:                  newRuntimeState(),
	}

	if err := server.ensureWritablePath(filepath.Dir(eventLogPath)); err != nil {
		logger.Fatalf("failed to prepare notifier event log path: %v", err)
	}
	if err := server.ensureWritablePath(filepath.Dir(remediationLogPath)); err != nil {
		logger.Fatalf("failed to prepare remediation log path: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/notify", server.handleNotify)
	mux.HandleFunc("/metrics", server.handleMetrics)
	mux.HandleFunc("/readyz", handleStaticOK)
	mux.HandleFunc("/healthz", handleStaticOK)

	go server.pollKubernetesEvents(context.Background())

	httpServer := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	startupEvent := notifierEvent{
		Type:      "notification",
		App:       "threadforge-notifier",
		Status:    "pass",
		Message:   "threadforge notifier started",
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Details: map[string]any{
			"watch_namespace":             watchNamespace,
			"event_log_path":              eventLogPath,
			"remediation_timeout_seconds": remediationTimeout.Seconds(),
		},
	}
	if err := server.processEvent(context.Background(), "startup", startupEvent, nil); err != nil {
		logger.Fatalf("failed to record startup event: %v", err)
	}

	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		logger.Fatalf("threadforge notifier exited: %v", err)
	}
}

func (s *notifierServer) handleNotify(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, http.StatusText(http.StatusMethodNotAllowed), http.StatusMethodNotAllowed)
		return
	}

	defer r.Body.Close()
	var payload notifierEvent
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	decoder.UseNumber()
	if err := decoder.Decode(&payload); err != nil {
		http.Error(w, "invalid json payload", http.StatusBadRequest)
		return
	}

	payload = normalizeEvent(payload)
	if !payload.isValid() {
		http.Error(w, "invalid event payload", http.StatusBadRequest)
		return
	}

	if err := s.processEvent(r.Context(), "http", payload, map[string]any{"remote_addr": r.RemoteAddr}); err != nil {
		http.Error(w, fmt.Sprintf("failed to process event: %v", err), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"status":      "ok",
		"type":        payload.Type,
		"run_id":      payload.RunID,
		"event_time":  payload.Timestamp,
		"event_app":   payload.App,
		"event_phase": payload.Phase,
	})
}

func (s *notifierServer) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	notificationTotals, forwardFailures, proofRunsTotal, proofFailuresTotal, phaseFailures, lastEvent := s.metrics.snapshot()
	notificationStatuses := make([]string, 0, len(notificationTotals))
	for status := range notificationTotals {
		notificationStatuses = append(notificationStatuses, status)
	}
	sort.Strings(notificationStatuses)
	phaseNames := make([]string, 0, len(phaseFailures))
	for phase := range phaseFailures {
		phaseNames = append(phaseNames, phase)
	}
	sort.Strings(phaseNames)

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = io.WriteString(w, "# HELP threadforge_notifications_total Total notifications processed by threadforge-notifier.\n")
	_, _ = io.WriteString(w, "# TYPE threadforge_notifications_total counter\n")
	for _, status := range notificationStatuses {
		_, _ = fmt.Fprintf(w, "threadforge_notifications_total{status=%q} %d\n", status, notificationTotals[status])
	}
	_, _ = io.WriteString(w, "# HELP threadforge_notifications_failures_total Total notification forwarding or watch failures.\n")
	_, _ = io.WriteString(w, "# TYPE threadforge_notifications_failures_total counter\n")
	_, _ = fmt.Fprintf(w, "threadforge_notifications_failures_total %d\n", forwardFailures)
	_, _ = io.WriteString(w, "# HELP threadforge_proof_runs_total Total proof final events processed by threadforge-notifier.\n")
	_, _ = io.WriteString(w, "# TYPE threadforge_proof_runs_total counter\n")
	_, _ = fmt.Fprintf(w, "threadforge_proof_runs_total %d\n", proofRunsTotal)
	_, _ = io.WriteString(w, "# HELP threadforge_proof_failures_total Total proof failures observed by threadforge-notifier.\n")
	_, _ = io.WriteString(w, "# TYPE threadforge_proof_failures_total counter\n")
	_, _ = fmt.Fprintf(w, "threadforge_proof_failures_total %d\n", proofFailuresTotal)
	_, _ = io.WriteString(w, "# HELP threadforge_proof_phase_failures_total Total unique proof phase failures observed by phase.\n")
	_, _ = io.WriteString(w, "# TYPE threadforge_proof_phase_failures_total counter\n")
	for _, phase := range phaseNames {
		_, _ = fmt.Fprintf(w, "threadforge_proof_phase_failures_total{phase=%q} %d\n", phase, phaseFailures[phase])
	}
	if lastEvent != "" {
		if ts, err := time.Parse(time.RFC3339, lastEvent); err == nil {
			_, _ = io.WriteString(w, "# HELP threadforge_notifications_last_event_timestamp_seconds Unix timestamp of the last processed notification.\n")
			_, _ = io.WriteString(w, "# TYPE threadforge_notifications_last_event_timestamp_seconds gauge\n")
			_, _ = fmt.Fprintf(w, "threadforge_notifications_last_event_timestamp_seconds %d\n", ts.Unix())
		}
	}
}

func handleStaticOK(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, `{"status":"ok"}`)
}

func extractNamespaceFromSPIFFE(spiffeID string) (string, error) {
	normalized := strings.TrimSpace(spiffeID)
	if !strings.HasPrefix(normalized, "spiffe://") {
		return "", fmt.Errorf("invalid SPIFFE identity: %q", spiffeID)
	}
	idx := strings.Index(normalized, "/ns/")
	if idx < 0 {
		return "", fmt.Errorf("SPIFFE identity missing namespace segment: %q", spiffeID)
	}
	rest := normalized[idx+len("/ns/"):]
	parts := strings.SplitN(rest, "/", 2)
	if len(parts) == 0 || strings.TrimSpace(parts[0]) == "" {
		return "", fmt.Errorf("SPIFFE identity contains empty namespace segment: %q", spiffeID)
	}
	return parts[0], nil
}

func resolveNotifierRole(spiffeID string) (string, error) {
	roleBySPIFFE := map[string]string{
		"spiffe://threadforge/ns/threadforge-test/sa/test-client":                           "test-client",
		"spiffe://identity.threadforge.local/ns/threadforge-test/sa/test-client":            "test-client",
		"spiffe://threadforge/ns/observability/sa/grafana":                                  "observability-reader",
		"spiffe://identity.threadforge.local/ns/observability/sa/grafana":                   "observability-reader",
		"spiffe://threadforge/ns/observability/sa/prometheus":                               "observability-reader",
		"spiffe://identity.threadforge.local/ns/observability/sa/prometheus":                "observability-reader",
		"spiffe://threadforge/ns/threadforge-system/sa/threadforge-notifier":                "notifier",
		"spiffe://identity.threadforge.local/ns/threadforge-system/sa/threadforge-notifier": "notifier",
		"spiffe://threadforge/ns/istio-system/sa/istio-ingressgateway":                      "ingress-gateway",
		"spiffe://identity.threadforge.local/ns/istio-system/sa/istio-ingressgateway":       "ingress-gateway",
		"spiffe://threadforge/ns/spire-system/sa/spire-server":                              "identity-control-plane",
		"spiffe://identity.threadforge.local/ns/spire-system/sa/spire-server":               "identity-control-plane",
	}

	normalized := strings.TrimSpace(spiffeID)
	if role, ok := roleBySPIFFE[normalized]; ok {
		return role, nil
	}
	return "", fmt.Errorf("unmapped SPIFFE identity: %s", normalized)
}

func (s *notifierServer) processEvent(ctx context.Context, source string, event notifierEvent, extra map[string]any) error {
	if strings.TrimSpace(s.notifierRole) == "" {
		return fmt.Errorf("notifier role unresolved; refusing to process event")
	}
	enriched := s.enrichEventRecord(source, event, extra)
	s.metrics.recordNotification(metricStatusLabel(event))
	if err := s.appendJSONLine(s.eventLogPath, enriched); err != nil {
		return err
	}
	s.logger.Print(mustMarshalJSON(enriched))
	s.recordProofMetrics(event)

	if err := s.forwardWebhook(ctx, s.webhookURL, event); err != nil {
		s.metrics.recordForwardFailure()
		s.logInternalEvent("webhook_failure", event, map[string]any{"error": err.Error(), "webhook_type": "primary"})
	}
	if event.Type == "proof_final" && strings.EqualFold(event.Final, "FAIL") {
		if err := s.forwardWebhook(ctx, s.failWebhookURL, event); err != nil {
			s.metrics.recordForwardFailure()
			s.logInternalEvent("webhook_failure", event, map[string]any{"error": err.Error(), "webhook_type": "failure"})
		}
		if err := s.handleProofFailure(ctx, event); err != nil {
			s.metrics.recordForwardFailure()
			s.logInternalEvent("remediation_error", event, map[string]any{"error": err.Error()})
		}
	}
	return nil
}

func (s *notifierServer) recordProofMetrics(event notifierEvent) {
	if event.Type == "proof_final" {
		if s.markProofRunSeen(event.RunID) {
			s.metrics.recordProofRun(strings.EqualFold(event.Final, "FAIL"))
		}
		return
	}
	if event.Type == "proof_phase" && strings.EqualFold(event.Status, "FAIL") {
		if s.markProofPhaseFailureSeen(event.RunID, event.Phase) {
			s.metrics.recordPhaseFailure(event.Phase)
		}
	}
}

func (s *notifierServer) handleProofFailure(ctx context.Context, event notifierEvent) error {
	decision := s.shouldRunRemediation(event)
	if !decision.ShouldRun {
		s.logInternalEvent("remediation_skipped", event, map[string]any{
			"reason":      decision.Reason,
			"fingerprint": decision.Hash,
		})
		return nil
	}
	if strings.TrimSpace(s.remediationCmd) == "" {
		s.logInternalEvent("alert", event, map[string]any{
			"message":     "proof failure observed with no remediation command configured",
			"fingerprint": decision.Hash,
		})
		return nil
	}

	execCtx, cancel := context.WithTimeout(ctx, s.remediationTimeout)
	defer cancel()
	command := exec.CommandContext(execCtx, "/bin/sh", "-lc", s.remediationCmd)
	command.Env = append(os.Environ(),
		"THREADFORGE_EVENT_TYPE="+event.Type,
		"THREADFORGE_EVENT_RUN_ID="+event.RunID,
		"THREADFORGE_EVENT_FAIL_CLASS="+event.FailClass,
		"THREADFORGE_EVENT_FINAL="+event.Final,
	)
	startedAt := time.Now().UTC()
	output, err := command.CombinedOutput()
	duration := time.Since(startedAt)
	outputText := strings.TrimSpace(string(output))
	if outputText != "" {
		_ = s.appendRemediationLog(event.RunID, outputText)
	}
	fields := map[string]any{
		"started_at":  startedAt.Format(time.RFC3339),
		"duration_ms": duration.Milliseconds(),
		"fingerprint": decision.Hash,
		"command":     s.remediationCmd,
		"output":      outputText,
	}
	if err != nil {
		fields["status"] = "fail"
		if execCtx.Err() == context.DeadlineExceeded {
			fields["error"] = fmt.Sprintf("remediation timed out after %s", s.remediationTimeout)
		} else {
			fields["error"] = err.Error()
		}
		s.logInternalEvent("remediation_result", event, fields)
		return err
	}
	fields["status"] = "pass"
	s.logInternalEvent("remediation_result", event, fields)
	return nil
}

func (s *notifierServer) shouldRunRemediation(event notifierEvent) remediationDecision {
	hash := proofFailureFingerprint(event)
	now := time.Now().UTC()
	s.state.mu.Lock()
	defer s.state.mu.Unlock()

	if strings.TrimSpace(s.remediationCmd) == "" {
		return remediationDecision{ShouldRun: false, Reason: "remediation command not configured", Hash: hash}
	}
	if event.RunID != "" {
		if s.state.remediationAttemptsByRun[event.RunID] >= s.remediationMaxAttempts {
			return remediationDecision{ShouldRun: false, Reason: "max remediation attempts reached for run", Hash: hash}
		}
	}
	if lastAt, ok := s.state.lastRemediationByHash[hash]; ok && now.Sub(lastAt) < s.remediationCooldown {
		return remediationDecision{ShouldRun: false, Reason: "identical failure inside cooldown window", Hash: hash}
	}
	if event.RunID != "" {
		s.state.remediationAttemptsByRun[event.RunID]++
	}
	s.state.lastRemediationByHash[hash] = now
	return remediationDecision{ShouldRun: true, Hash: hash}
}

func (s *notifierServer) markProofRunSeen(runID string) bool {
	key := runID
	if key == "" {
		key = fmt.Sprintf("anon-run:%d", time.Now().UTC().UnixNano())
	}
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	if _, ok := s.state.proofRunsSeen[key]; ok {
		return false
	}
	s.state.proofRunsSeen[key] = struct{}{}
	return true
}

func (s *notifierServer) markProofPhaseFailureSeen(runID string, phase string) bool {
	key := phase
	if runID != "" {
		key = runID + "|" + phase
	}
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	if _, ok := s.state.proofPhaseFailuresSeen[key]; ok {
		return false
	}
	s.state.proofPhaseFailuresSeen[key] = struct{}{}
	return true
}

func (s *notifierServer) forwardWebhook(ctx context.Context, url string, event notifierEvent) error {
	if strings.TrimSpace(url) == "" {
		return nil
	}
	body, err := json.Marshal(event)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("downstream webhook returned status %d", resp.StatusCode)
	}
	return nil
}

func (s *notifierServer) logInternalEvent(source string, event notifierEvent, extra map[string]any) {
	record := s.enrichEventRecord(source, notifierEvent{
		Type:      event.Type,
		App:       event.App,
		Status:    normalizeNotificationStatus(event.Status),
		Message:   deriveMessage(event),
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		RunID:     event.RunID,
		Phase:     event.Phase,
		Final:     event.Final,
		FailClass: event.FailClass,
	}, extra)
	if err := s.appendJSONLine(s.eventLogPath, record); err == nil {
		s.logger.Print(mustMarshalJSON(record))
	}
}

func (s *notifierServer) enrichEventRecord(source string, event notifierEvent, extra map[string]any) map[string]any {
	auditResult := "ALLOW"
	if strings.EqualFold(event.Status, "fail") || strings.EqualFold(event.Final, "FAIL") {
		auditResult = "ERROR"
	}
	if source == "watch_error" {
		auditResult = "ERROR"
	}

	record := map[string]any{
		"component":   "threadforge-notifier",
		"source":      source,
		"received_at": time.Now().UTC().Format(time.RFC3339),
		"event":       event,
		"audit": map[string]any{
			"timestamp":       time.Now().UTC().Format(time.RFC3339),
			"actor_spiffe_id": s.notifierSpiffeID,
			"actor_role":      s.notifierRole,
			"namespace":       s.notifierNamespace,
			"action":          "NOTIFIER_EVENT_PROCESS",
			"resource":        fmt.Sprintf("event/%s", event.Type),
			"result":          auditResult,
			"reason":          source,
		},
	}
	for key, value := range extra {
		record[key] = value
	}
	return record
}

func (s *notifierServer) ensureWritablePath(path string) error {
	return os.MkdirAll(path, 0o755)
}

func (s *notifierServer) appendJSONLine(path string, payload any) error {
	s.fileMu.Lock()
	defer s.fileMu.Unlock()
	if err := s.ensureWritablePath(filepath.Dir(path)); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer file.Close()
	encoded, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	_, err = file.Write(append(encoded, '\n'))
	return err
}

func (s *notifierServer) appendRemediationLog(runID string, output string) error {
	s.fileMu.Lock()
	defer s.fileMu.Unlock()
	if err := s.ensureWritablePath(filepath.Dir(s.remediationLogPath)); err != nil {
		return err
	}
	file, err := os.OpenFile(s.remediationLogPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer file.Close()
	line := fmt.Sprintf("%s run_id=%s output=%s\n", time.Now().UTC().Format(time.RFC3339), runID, strings.ReplaceAll(output, "\n", " | "))
	_, err = file.WriteString(line)
	return err
}

func (s *notifierServer) pollKubernetesEvents(ctx context.Context) {
	ticker := time.NewTicker(s.pollInterval)
	defer ticker.Stop()
	s.pollEventPage(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.pollEventPage(ctx)
		}
	}
}

func (s *notifierServer) pollEventPage(ctx context.Context) {
	url := fmt.Sprintf("%s/api/v1/namespaces/%s/events?limit=200", s.kubeAPIBase, s.watchNamespace)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		s.metrics.recordForwardFailure()
		s.logInternalEvent("watch_error", notifierEvent{App: "argocd", Status: "fail", Message: err.Error(), Timestamp: time.Now().UTC().Format(time.RFC3339)}, nil)
		return
	}
	req.Header.Set("Authorization", "Bearer "+s.kubeToken)

	resp, err := s.kubeClient.Do(req)
	if err != nil {
		s.metrics.recordForwardFailure()
		s.logInternalEvent("watch_error", notifierEvent{App: "argocd", Status: "fail", Message: err.Error(), Timestamp: time.Now().UTC().Format(time.RFC3339)}, nil)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		s.metrics.recordForwardFailure()
		s.logInternalEvent("watch_error", notifierEvent{App: "argocd", Status: "fail", Message: fmt.Sprintf("kubernetes events query failed: %d", resp.StatusCode), Timestamp: time.Now().UTC().Format(time.RFC3339)}, nil)
		return
	}

	var payload struct {
		Items []kubernetesEvent `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		s.metrics.recordForwardFailure()
		s.logInternalEvent("watch_error", notifierEvent{App: "argocd", Status: "fail", Message: err.Error(), Timestamp: time.Now().UTC().Format(time.RFC3339)}, nil)
		return
	}

	for _, item := range payload.Items {
		if !isRelevantArgoCDEvent(item) {
			continue
		}
		if _, loaded := s.seenEvents.LoadOrStore(item.Metadata.UID, struct{}{}); loaded {
			continue
		}
		status := normalizeNotificationStatus(item.Type)
		message := strings.TrimSpace(item.Message)
		if message == "" {
			message = strings.TrimSpace(item.Reason)
		}
		appName := item.InvolvedObject.Name
		if appName == "" {
			appName = "argocd"
		}
		timestamp := item.Metadata.CreationTimestamp
		if timestamp == "" {
			timestamp = time.Now().UTC().Format(time.RFC3339)
		}
		event := normalizeEvent(notifierEvent{
			Type:      "notification",
			App:       appName,
			Status:    status,
			Message:   message,
			Timestamp: timestamp,
			Details: map[string]any{
				"reason":       item.Reason,
				"event_type":   item.Type,
				"object_kind":  item.InvolvedObject.Kind,
				"watch_source": componentName(item),
			},
		})
		if err := s.processEvent(ctx, "kubernetes-event", event, nil); err != nil {
			s.metrics.recordForwardFailure()
			s.logInternalEvent("watch_error", event, map[string]any{"error": err.Error()})
		}
	}
}

func isRelevantArgoCDEvent(item kubernetesEvent) bool {
	if item.InvolvedObject.Namespace != "argocd" {
		return false
	}
	if strings.HasPrefix(item.InvolvedObject.Name, "argocd-") {
		return true
	}
	kind := strings.ToLower(item.InvolvedObject.Kind)
	if kind == "application" || kind == "applications.argoproj.io" {
		return true
	}
	component := strings.ToLower(componentName(item))
	return strings.Contains(component, "argocd")
}

func componentName(item kubernetesEvent) string {
	if item.ReportingComponent != "" {
		return item.ReportingComponent
	}
	if item.Source.Component != "" {
		return item.Source.Component
	}
	return "kubernetes"
}

func normalizeEvent(event notifierEvent) notifierEvent {
	event.Type = strings.TrimSpace(strings.ToLower(event.Type))
	if event.Type == "" {
		event.Type = "notification"
	}
	event.App = strings.TrimSpace(event.App)
	event.RunID = strings.TrimSpace(event.RunID)
	event.Phase = strings.TrimSpace(event.Phase)
	event.FailClass = strings.TrimSpace(event.FailClass)
	if event.Timestamp == "" {
		event.Timestamp = time.Now().UTC().Format(time.RFC3339)
	}
	if event.Details == nil {
		event.Details = map[string]any{}
	}

	switch event.Type {
	case "proof_phase":
		event.Status = normalizePhaseStatus(event.Status)
		if event.App == "" {
			event.App = "threadforge-proof"
		}
	case "proof_final":
		event.Final = normalizePhaseStatus(coalesce(event.Final, event.Status))
		event.Status = event.Final
		if event.App == "" {
			event.App = "threadforge-proof"
		}
	default:
		event.Status = normalizeNotificationStatus(event.Status)
		if event.App == "" {
			event.App = "threadforge-notifier"
		}
	}

	event.Message = strings.TrimSpace(event.Message)
	if event.Message == "" {
		event.Message = deriveMessage(event)
	}
	return event
}

func (e notifierEvent) isValid() bool {
	switch e.Type {
	case "proof_phase":
		return e.Phase != "" && e.Status != ""
	case "proof_final":
		return e.Final != ""
	default:
		return e.App != "" && e.Message != ""
	}
}

func deriveMessage(event notifierEvent) string {
	switch event.Type {
	case "proof_phase":
		return fmt.Sprintf("proof phase %s %s", event.Phase, strings.ToLower(event.Status))
	case "proof_final":
		return fmt.Sprintf("proof final %s fail_class=%s", strings.ToLower(event.Final), strings.ToLower(coalesce(event.FailClass, "none")))
	default:
		return coalesce(event.Message, "threadforge notification")
	}
}

func normalizeNotificationStatus(raw string) string {
	status := strings.ToLower(strings.TrimSpace(raw))
	if status == "" {
		return "unknown"
	}
	switch status {
	case "normal", "success", "ready", "running", "pass", "passed":
		return "pass"
	case "warning", "error", "failed", "failure", "critical", "fail":
		return "fail"
	default:
		return status
	}
}

func normalizePhaseStatus(raw string) string {
	status := strings.ToUpper(strings.TrimSpace(raw))
	if status == "" {
		return "UNKNOWN"
	}
	return status
}

func metricStatusLabel(event notifierEvent) string {
	if event.Type == "proof_phase" || event.Type == "proof_final" {
		return strings.ToLower(event.Status)
	}
	return normalizeNotificationStatus(event.Status)
}

func proofFailureFingerprint(event notifierEvent) string {
	payload := map[string]any{
		"type":       event.Type,
		"phase":      event.Phase,
		"final":      event.Final,
		"fail_class": event.FailClass,
		"details":    event.Details,
	}
	raw, _ := json.Marshal(payload)
	sum := sha256.Sum256(raw)
	return fmt.Sprintf("%x", sum[:])
}

func mustMarshalJSON(payload any) string {
	raw, err := json.Marshal(payload)
	if err != nil {
		return `{"component":"threadforge-notifier","status":"fail","message":"json marshal error"}`
	}
	return string(raw)
}

func envOrDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func envIntOrDefault(key string, fallback int) int {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return fallback
	}
	return value
}

func envDurationOrDefault(key string, fallback time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}
	value, err := time.ParseDuration(raw)
	if err != nil {
		return fallback
	}
	return value
}

func coalesce(values ...string) string {
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func discoverInClusterConfig() (string, string, *tls.Config, error) {
	host := strings.TrimSpace(os.Getenv("KUBERNETES_SERVICE_HOST"))
	port := strings.TrimSpace(os.Getenv("KUBERNETES_SERVICE_PORT"))
	if host == "" || port == "" {
		return "", "", nil, fmt.Errorf("KUBERNETES_SERVICE_HOST/KUBERNETES_SERVICE_PORT are required")
	}

	tokenPath := "/var/run/secrets/kubernetes.io/serviceaccount/token"
	caPath := "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
	tokenBytes, err := os.ReadFile(tokenPath)
	if err != nil {
		return "", "", nil, fmt.Errorf("read serviceaccount token: %w", err)
	}
	caBytes, err := os.ReadFile(filepath.Clean(caPath))
	if err != nil {
		return "", "", nil, fmt.Errorf("read serviceaccount CA bundle: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caBytes) {
		return "", "", nil, fmt.Errorf("failed to load kubernetes CA bundle")
	}

	return fmt.Sprintf("https://%s:%s", host, port), strings.TrimSpace(string(tokenBytes)), &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool}, nil
}
