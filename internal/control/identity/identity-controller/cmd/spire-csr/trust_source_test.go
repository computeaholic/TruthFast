package main

import "testing"

func TestBuildPodsAPIURL(t *testing.T) {
	got, err := buildPodsAPIURL("https://kubernetes.default.svc:443", "spire-system", "app=spire-server")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := "https://kubernetes.default.svc:443/api/v1/namespaces/spire-system/pods?fieldSelector=status.phase%3DRunning&labelSelector=app%3Dspire-server"
	if got != want {
		t.Fatalf("unexpected URL\nwant: %s\n got: %s", want, got)
	}
}

func TestResolveTTLHonorsProofOverrideAfterTrustSourceHookChanges(t *testing.T) {
	overrides := map[string]int32{"threadforge-test": 300}
	ttl := resolveTTL(
		"spiffe://identity.threadforge.local/ns/threadforge-test/sa/default",
		"identity.threadforge.local",
		3600,
		0,
		overrides,
	)
	if ttl != 300 {
		t.Fatalf("expected proof override TTL 300, got %d", ttl)
	}
}
