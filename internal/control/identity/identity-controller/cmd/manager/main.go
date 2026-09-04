package main

import (
	"context"
	"flag"
	"os"
	"time"

	idv1 "threadforge/controllers/identity/identity-controller/api/v1"
	"threadforge/controllers/identity/identity-controller/controllers"
	"threadforge/controllers/identity/identity-controller/internal/identity"
	"threadforge/controllers/identity/identity-controller/internal/spire"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"

	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"go.uber.org/zap/zapcore"
)

var (
	scheme   = runtime.NewScheme()
	setupLog = ctrl.Log.WithName("setup")
)

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(idv1.AddToScheme(scheme))
}

func main() {
	var (
		metricsAddr          string
		healthProbeAddr      string
		enableLeaderElection bool
	)

	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "The address the metric endpoint binds to.")
	flag.StringVar(&healthProbeAddr, "health-probe-bind-address", ":8081", "The address the probe endpoint binds to.")
	flag.BoolVar(&enableLeaderElection, "leader-elect", false, "Enable leader election for controller manager.")

	opts := zap.Options{
		TimeEncoder: zapcore.ISO8601TimeEncoder,
	}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		HealthProbeBindAddress: healthProbeAddr,
		LeaderElection:         enableLeaderElection,
		LeaderElectionID:       "identity-controller.threadforge.local",
	})
	if err != nil {
		setupLog.Error(err, "unable to start manager")
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Phase A.2: Validate multi-node configuration before initializing SPIRE client
	// This is a hard requirement: deployment must explicitly declare multi-node mode
	// or match the actual cluster topology.
	multiNodeGuard := identity.NewMultiNodeGuard()
	if err := multiNodeGuard.ValidateMultiNode(); err != nil {
		setupLog.Error(err, "MULTI_NODE_MODE validation failed (hard enforcement)")
		os.Exit(1)
	}
	if err := multiNodeGuard.ValidateExplicitMultiNode(); err != nil {
		setupLog.Error(err, "explicit multi-node declaration mismatch (hard enforcement)")
		os.Exit(1)
	}
	if err := multiNodeGuard.ValidateBootstrapPolicy(); err != nil {
		setupLog.Error(err, "bootstrap policy validation failed (hard enforcement)")
		os.Exit(1)
	}
	setupLog.Info("multi-node and bootstrap policy validation passed")

	spireAddr := os.Getenv("SPIRE_SERVER_ADDR")
	if spireAddr == "" {
		spireAddr = "/run/spire/private/spire-server.sock"
	}

	spireClient, err := spire.NewAdmin(ctx, spireAddr)
	if err != nil {
		setupLog.Error(err, "unable to initialize SPIRE client")
		os.Exit(1)
	}

	if err = (&controllers.IdentityRegistrationReconciler{
		Client:          mgr.GetClient(),
		Scheme:          mgr.GetScheme(),
		Spire:           spireClient,
		SpireServerAddr: spireAddr,
		EventRecorder:   mgr.GetEventRecorderFor("identity-registration-controller"),
	}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to create IdentityRegistration controller")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	setupLog.Info("starting identity controller manager")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "problem running manager")
		os.Exit(1)
	}
}
