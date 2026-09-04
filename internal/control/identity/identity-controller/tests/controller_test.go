package controllers

import (
	"context"
	"errors"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	idv1 "threadforge/controllers/identity/identity-controller/api/v1"
	"threadforge/controllers/identity/identity-controller/internal/spire"

	"github.com/spiffe/spire-api-sdk/proto/spire/api/types"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// MockSPIREClient implements SPIREClient for testing
type MockSPIREClient struct {
	entries map[string][]*types.Entry
}

func (m *MockSPIREClient) Create(ctx context.Context, entry *types.Entry) (*types.Entry, error) {
	return nil, errors.New("not implemented")
}

func (m *MockSPIREClient) Update(ctx context.Context, entry *types.Entry) (*types.Entry, error) {
	return nil, errors.New("not implemented")
}

func (m *MockSPIREClient) ListBySpiffeID(ctx context.Context, spiffeID string) ([]*types.Entry, error) {
	return m.entries[spiffeID], nil
}

func (m *MockSPIREClient) Delete(ctx context.Context, id string) error {
	return errors.New("not implemented")
}

var _ = Describe("IdentityRegistration Controller", func() {
	var (
		reconciler *IdentityRegistrationReconciler
		req        ctrl.Request
		ctx        context.Context
	)

	BeforeEach(func() {
		scheme := runtime.NewScheme()
		Expect(idv1.AddToScheme(scheme)).To(Succeed())

		reconciler = &IdentityRegistrationReconciler{
			Client:        fake.NewClientBuilder().WithScheme(scheme).Build(),
			Scheme:        scheme,
			EventRecorder: record.NewFakeRecorder(10),
		}

		req = ctrl.Request{
			NamespacedName: types.NamespacedName{
				Name:      "test-identity",
				Namespace: "default",
			},
		}
		ctx = context.Background()
	})

	Context("Safety over Liveness", func() {
		It("should block deletion when multiple SPIRE entries exist", func() {
			// Create a test IdentityRegistration
			reg := &idv1.IdentityRegistration{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-identity",
					Namespace: "default",
				},
				Spec: idv1.IdentityRegistrationSpec{
					SpiffeID: "spiffe://example.org/test",
				},
			}
			reg.DeletionTimestamp = &metav1.Time{Time: metav1.Now().Time} // Mark for deletion

			Expect(reconciler.Client.Create(ctx, reg)).To(Succeed())

			// Mock SPIRE client with multiple entries (safety violation)
			mockClient := &MockSPIREClient{
				entries: map[string][]*types.Entry{
					"spiffe://example.org/test": {
						{Id: "entry1"},
						{Id: "entry2"}, // Multiple entries - should cause failure
					},
				},
			}
			reconciler.Spire = mockClient

			// Reconcile should fail due to multiple entries
			result, err := reconciler.Reconcile(ctx, req)

			// Should return error due to safety violation
			Expect(err).To(HaveOccurred())
			Expect(err).To(BeAssignableToTypeOf(&spire.MultipleEntriesError{}))

			// Should not requeue immediately (safety over liveness)
			Expect(result.RequeueAfter).To(BeZero())

			// Verify the error details
			var multipleErr *spire.MultipleEntriesError
			Expect(errors.As(err, &multipleErr)).To(BeTrue())
			Expect(multipleErr.SPIFFEID).To(Equal("spiffe://example.org/test"))
			Expect(multipleErr.Count).To(Equal(2))
		})
	})
})