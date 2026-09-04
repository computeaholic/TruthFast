package controllers

import (
	"context"
	"time"

	idv1 "threadforge/controllers/identity/identity-controller/api/v1"
	"threadforge/controllers/identity/identity-controller/internal/diff"
	"threadforge/controllers/identity/identity-controller/internal/spire"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/spiffe/spire-api-sdk/proto/spire/api/types"
)

type SPIREClient interface {
	Create(ctx context.Context, entry *types.Entry) (*types.Entry, error)
	Update(ctx context.Context, entry *types.Entry) (*types.Entry, error)
	ListBySpiffeID(ctx context.Context, spiffeID string) ([]*types.Entry, error)
	Delete(ctx context.Context, id string) error
}

const (
	finalizerName = "identity.threadforge.local/spire-entry-cleanup"

	// Condition types
	ConditionTypeReady = "Ready"

	// Condition reasons
	ReasonReconciled         = "Reconciled"
	ReasonReconciliationFailed = "ReconciliationFailed"
	ReasonDriftDetected      = "DriftDetected"
	ReasonSPIREUnavailable   = "SPIREUnavailable"
	ReasonMultipleEntries    = "MultipleEntries"
)

var (
	// Metrics
	reconcileTotal = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "identity_registration_reconcile_total",
			Help: "Total number of reconciliations",
		},
	)

	spireOperationsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "identity_registration_spire_operations_total",
			Help: "Total number of SPIRE operations",
		},
		[]string{"operation", "result"},
	)

	finalizerBlockTotal = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "identity_registration_finalizer_block_total",
			Help: "Total number of finalizer blocks",
		},
	)
)

// IdentityRegistrationReconciler reconciles IdentityRegistration CRs into SPIRE.
type IdentityRegistrationReconciler struct {
	client.Client
	Scheme *runtime.Scheme

	Spire SPIREClient

	// Configuration (explicit, no magic)
	SpireServerAddr string

	// EventRecorder for recording events
	EventRecorder record.EventRecorder
}

// Reconcile implements the reconciliation loop.
// NOTE: This controller intentionally favors safety over liveness.
// Any ambiguous SPIRE state results in a hard stop requiring human intervention.
func (r *IdentityRegistrationReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	reconcileTotal.Inc()

	logger := log.FromContext(ctx)

	var reg idv1.IdentityRegistration
	if err := r.Get(ctx, req.NamespacedName, &reg); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	// Handle deletion
	if !reg.ObjectMeta.DeletionTimestamp.IsZero() {
		return r.handleDeletion(ctx, &reg)
	}

	// Ensure finalizer is present
	if !controllerutil.ContainsFinalizer(&reg, finalizerName) {
		controllerutil.AddFinalizer(&reg, finalizerName)
		if err := r.Update(ctx, &reg); err != nil {
			return ctrl.Result{}, err
		}
	}

	// Build desired SPIRE entry
	desired := spire.EntryFromSpec(&reg)

	// Fetch existing SPIRE entries
	existing, err := r.Spire.ListBySpiffeID(ctx, reg.Spec.SpiffeID)
	if err != nil {
		logger.Error(err, "failed to list SPIRE entries")
		return r.failStatus(ctx, &reg, err)
	}

	switch len(existing) {

	case 0:
		created, err := r.Spire.Create(ctx, desired)
		if err != nil {
			spireOperationsTotal.WithLabelValues("create", "error").Inc()
			return r.failStatus(ctx, &reg, err)
		}
		spireOperationsTotal.WithLabelValues("create", "success").Inc()
		return r.successStatus(ctx, &reg, created.Id)

	case 1:
		if diff.Equal(existing[0], desired) {
			return r.reconciledNoop(ctx, &reg, existing[0].Id)
		}

		desired.Id = existing[0].Id
		updated, err := r.Spire.Update(ctx, desired)
		if err != nil {
			spireOperationsTotal.WithLabelValues("update", "error").Inc()
			return r.failStatus(ctx, &reg, err)
		}
		spireOperationsTotal.WithLabelValues("update", "success").Inc()
		return r.successStatus(ctx, &reg, updated.Id)

	default:
		return r.failStatus(ctx, &reg,
			spire.NewMultipleEntriesError(reg.Spec.SpiffeID, len(existing)),
		)
	}
}

// SetupWithManager wires the controller into controller-runtime.
func (r *IdentityRegistrationReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&idv1.IdentityRegistration{}).
		Complete(r)
}

// ---- status helpers (fact-only) ----

func (r *IdentityRegistrationReconciler) reconciledNoop(
	ctx context.Context,
	reg *idv1.IdentityRegistration,
	entryID string,
) (ctrl.Result, error) {

	now := metav1.Now()
	reg.Status.Reconciled = true
	reg.Status.SpireEntryID = entryID
	reg.Status.ObservedGeneration = reg.Generation
	reg.Status.LastSyncTime = &now
	reg.Status.Error = ""

	// Set ready condition
	setCondition(reg, ConditionTypeReady, metav1.ConditionTrue, ReasonReconciled, "Identity registration is up to date")

	return ctrl.Result{}, r.updateStatus(ctx, reg)
}

func (r *IdentityRegistrationReconciler) successStatus(
	ctx context.Context,
	reg *idv1.IdentityRegistration,
	entryID string,
) (ctrl.Result, error) {

	now := metav1.Now()
	reg.Status.Reconciled = true
	reg.Status.SpireEntryID = entryID
	reg.Status.ObservedGeneration = reg.Generation
	reg.Status.LastSyncTime = &now
	reg.Status.Error = ""

	// Set ready condition
	setCondition(reg, ConditionTypeReady, metav1.ConditionTrue, ReasonReconciled, "Identity registration successfully created/updated")

	// Record event
	r.EventRecorder.Event(reg, "Normal", "EntryCreated", "SPIRE entry created/updated successfully")

	return ctrl.Result{}, r.updateStatus(ctx, reg)
}

func (r *IdentityRegistrationReconciler) failStatus(
	ctx context.Context,
	reg *idv1.IdentityRegistration,
	err error,
) (ctrl.Result, error) {

	reg.Status.Reconciled = false
	reg.Status.Error = err.Error()

	// Set error condition
	setCondition(reg, ConditionTypeReady, metav1.ConditionFalse, ReasonReconciliationFailed, err.Error())

	// Record event
	r.EventRecorder.Event(reg, "Warning", "ReconciliationFailed", err.Error())

	_ = r.updateStatus(ctx, reg)

	return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
}

// setCondition is a helper to set status conditions
func setCondition(reg *idv1.IdentityRegistration, conditionType string, status metav1.ConditionStatus, reason, message string) {
	now := metav1.Now()
	condition := metav1.Condition{
		Type:               conditionType,
		Status:             status,
		Reason:             reason,
		Message:            message,
		LastTransitionTime: now,
	}

	// Find existing condition
	for i, existing := range reg.Status.Conditions {
		if existing.Type == conditionType {
			// Update existing condition
			if existing.Status != status || existing.Reason != reason || existing.Message != message {
				reg.Status.Conditions[i] = condition
			}
			return
		}
	}

	// Add new condition
	reg.Status.Conditions = append(reg.Status.Conditions, condition)
}

// updateStatus is a helper to update status, ensuring spec and status never mix
func (r *IdentityRegistrationReconciler) updateStatus(ctx context.Context, reg *idv1.IdentityRegistration) error {
	return r.Status().Update(ctx, reg)
}

func (r *IdentityRegistrationReconciler) handleDeletion(
	ctx context.Context,
	reg *idv1.IdentityRegistration,
) (ctrl.Result, error) {

	// Build SPIFFE ID from spec
	spiffeIDStr := reg.Spec.SpiffeID

	// Fetch existing SPIRE entries
	entries, err := r.Spire.ListBySpiffeID(ctx, spiffeIDStr)
	if err != nil {
		return ctrl.Result{}, err
	}

	switch len(entries) {
	case 0:
		// Already clean — proceed
	case 1:
		if err := r.Spire.Delete(ctx, entries[0].Id); err != nil {
			spireOperationsTotal.WithLabelValues("delete", "error").Inc()
			return ctrl.Result{}, err
		}
		spireOperationsTotal.WithLabelValues("delete", "success").Inc()
		// Record deletion event
		r.EventRecorder.Event(reg, "Normal", "EntryDeleted", "SPIRE entry deleted successfully")
	default:
		// Safety over liveness
		return ctrl.Result{}, spire.NewMultipleEntriesError(reg.Spec.SpiffeID, len(entries))
	}

	// Remove finalizer
	controllerutil.RemoveFinalizer(reg, finalizerName)
	if err := r.Update(ctx, reg); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}
