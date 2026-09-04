package v1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,shortName=idreg
// +kubebuilder:group=identity.threadforge.local
// +kubebuilder:version=v1

// IdentityRegistration represents a single declarative SPIRE
// registration entry derived exclusively from the identity compiler.
// It encodes no behavior and no policy.
type IdentityRegistration struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   IdentityRegistrationSpec   `json:"spec,omitempty"`
	Status IdentityRegistrationStatus `json:"status,omitempty"`
}

// IdentityRegistrationSpec mirrors compiler output exactly.
// +kubebuilder:object:generate=true
type IdentityRegistrationSpec struct {
	// Fully-qualified SPIFFE ID for the workload identity.
	SpiffeID string `json:"spiffeId"`

	// SPIFFE ID of the parent identity.
	ParentID string `json:"parentId"`

	// Selector set binding identity to workload attributes.
	Selectors []Selector `json:"selectors"`

	// Optional SPIRE TTL (seconds). Nil means SPIRE default.
	TTL *int32 `json:"ttl,omitempty"`

	// Optional metadata for audit and provenance.
	// Not interpreted by the controller.
	Annotations map[string]string `json:"annotations,omitempty"`
}

// Selector binds an identity to an attribute.
type Selector struct {
	Type  string `json:"type"`
	Value string `json:"value"`
}

// IdentityRegistrationStatus reports observed reconciliation state.
// +kubebuilder:object:generate=true
type IdentityRegistrationStatus struct {
	// Last observed metadata.generation.
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// True if desired state matches SPIRE state.
	Reconciled bool `json:"reconciled,omitempty"`

	// SPIRE-assigned entry ID, if known.
	SpireEntryID string `json:"spireEntryId,omitempty"`

	// RFC3339 timestamp of last successful sync.
	LastSyncTime *metav1.Time `json:"lastSyncTime,omitempty"`

	// Last reconciliation error, if any.
	Error string `json:"error,omitempty"`

	// Conditions represent the latest available observations of the identity registration's state.
	// +patchMergeKey=type
	// +patchStrategy=merge
	// +listType=map
	// +listMapKey=type
	Conditions []metav1.Condition `json:"conditions,omitempty" patchStrategy:"merge" patchMergeKey:"type"`
}

// +kubebuilder:object:root=true

// IdentityRegistrationList contains a list of IdentityRegistration.
type IdentityRegistrationList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []IdentityRegistration `json:"items"`
}

func init() {
	SchemeBuilder.Register(
		&IdentityRegistration{},
		&IdentityRegistrationList{},
	)
}
