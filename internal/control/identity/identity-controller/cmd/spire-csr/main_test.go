package main

import "testing"

func TestResolveTTLUsesNamespaceOverrideAsUpperBound(t *testing.T) {
	overrides := map[string]int32{"threadforge-test": 300}

	ttl := resolveTTL(
		"spiffe://identity.threadforge.local/ns/threadforge-test/sa/default",
		"identity.threadforge.local",
		3600,
		86400,
		overrides,
	)

	if ttl != 300 {
		t.Fatalf("expected namespace override TTL 300, got %d", ttl)
	}
}

func TestResolveTTLLeavesOtherNamespacesUnchanged(t *testing.T) {
	overrides := map[string]int32{"threadforge-test": 300}

	ttl := resolveTTL(
		"spiffe://identity.threadforge.local/ns/threadforge-prod/sa/default",
		"identity.threadforge.local",
		3600,
		86400,
		overrides,
	)

	if ttl != 86400 {
		t.Fatalf("expected requested TTL 86400 for non-proof namespace, got %d", ttl)
	}
}

func TestParseNamespaceTTLOverrides(t *testing.T) {
	overrides, err := parseNamespaceTTLOverrides("threadforge-test=300,threadforge-smoke=120")
	if err != nil {
		t.Fatalf("unexpected parse error: %v", err)
	}

	if got := overrides["threadforge-test"]; got != 300 {
		t.Fatalf("expected threadforge-test override 300, got %d", got)
	}
	if got := overrides["threadforge-smoke"]; got != 120 {
		t.Fatalf("expected threadforge-smoke override 120, got %d", got)
	}
}
