package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	csi "github.com/container-storage-interface/spec/lib/go/csi"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	pluginregistration "k8s.io/kubelet/pkg/apis/pluginregistration/v1"
)

var (
	listenSocket  string
	backendSocket string
)

func init() {
	flag.StringVar(&listenSocket,
		"listen-socket",
		"/var/lib/kubelet/plugins_registry/csi.spiffe.io-reg.sock",
		"host registration unix socket to listen on",
	)
	flag.StringVar(&backendSocket,
		"backend-socket",
		"/registration/csi.spiffe.io-reg.sock",
		"internal registrar unix socket to forward to",
	)
	flag.Parse()
}

/*
regProxy owns the *host* registration socket.
It intercepts NodeGetInfo locally and forwards all other RPCs
to the real registrar over a pod-internal socket.
*/
type regProxy struct {
	backendTarget string
	backendConn   atomic.Value // *grpc.ClientConn (registrar)
	driverTarget  string
	driverConn    atomic.Value // *grpc.ClientConn (driver socket)
	nodeID        string
	pluginregistration.UnimplementedRegistrationServer
}

func (r *regProxy) ensureBackend() (*grpc.ClientConn, error) {
	if v := r.backendConn.Load(); v != nil {
		return v.(*grpc.ClientConn), nil
	}

	conn, err := dialBackendWithRetry(r.backendTarget, 0) // infinite retry
	if err != nil {
		return nil, err
	}
	r.backendConn.Store(conn)
	return conn, nil
}

func (r *regProxy) forwardUnary(ctx context.Context, method string, req, resp interface{}) error {
	conn, err := r.ensureBackend()
	if err != nil {
		return status.Error(codes.Unavailable, "backend registrar not ready")
	}
	return conn.Invoke(ctx, method, req, resp)
}

// forwardUnaryToDriver forwards Identity/Probe RPCs directly to the CSI driver socket.
func (r *regProxy) forwardUnaryToDriver(ctx context.Context, method string, req, resp interface{}) error {
	// Ensure driver connection (short timeout)
	if v := r.driverConn.Load(); v == nil {
		// attempt a quick dial (no infinite retry)
		conn, err := dialBackendWithRetry(r.driverTarget, 5*time.Second)
		if err != nil {
			return status.Error(codes.Unavailable, "driver socket not ready")
		}
		r.driverConn.Store(conn)
	}
	conn := r.driverConn.Load().(*grpc.ClientConn)
	return conn.Invoke(ctx, method, req, resp)
}

/* ---------------- Node interception ---------------- */

func (r *regProxy) NodeGetInfo(ctx context.Context, req *csi.NodeGetInfoRequest) (*csi.NodeGetInfoResponse, error) {
	log.Printf("reg-proxy: NodeGetInfo intercepted, nodeID=%s", r.nodeID)
	if r.nodeID == "" {
		return nil, status.Error(codes.Internal, "node id unavailable")
	}
	return &csi.NodeGetInfoResponse{NodeId: r.nodeID}, nil
}

func (r *regProxy) NodeGetCapabilities(ctx context.Context, req *csi.NodeGetCapabilitiesRequest) (*csi.NodeGetCapabilitiesResponse, error) {
	var resp csi.NodeGetCapabilitiesResponse
	if err := r.forwardUnaryToDriver(ctx, "/csi.v1.Node/NodeGetCapabilities", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (r *regProxy) NodePublishVolume(ctx context.Context, req *csi.NodePublishVolumeRequest) (*csi.NodePublishVolumeResponse, error) {
	var resp csi.NodePublishVolumeResponse
	if err := r.forwardUnaryToDriver(ctx, "/csi.v1.Node/NodePublishVolume", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (r *regProxy) NodeUnpublishVolume(ctx context.Context, req *csi.NodeUnpublishVolumeRequest) (*csi.NodeUnpublishVolumeResponse, error) {
	var resp csi.NodeUnpublishVolumeResponse
	if err := r.forwardUnaryToDriver(ctx, "/csi.v1.Node/NodeUnpublishVolume", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (r *regProxy) NodeStageVolume(ctx context.Context, req *csi.NodeStageVolumeRequest) (*csi.NodeStageVolumeResponse, error) {
	var resp csi.NodeStageVolumeResponse
	if err := r.forwardUnaryToDriver(ctx, "/csi.v1.Node/NodeStageVolume", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (r *regProxy) NodeUnstageVolume(ctx context.Context, req *csi.NodeUnstageVolumeRequest) (*csi.NodeUnstageVolumeResponse, error) {
	var resp csi.NodeUnstageVolumeResponse
	if err := r.forwardUnaryToDriver(ctx, "/csi.v1.Node/NodeUnstageVolume", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (r *regProxy) NodeGetVolumeStats(ctx context.Context, req *csi.NodeGetVolumeStatsRequest) (*csi.NodeGetVolumeStatsResponse, error) {
	var resp csi.NodeGetVolumeStatsResponse
	if err := r.forwardUnaryToDriver(ctx, "/csi.v1.Node/NodeGetVolumeStats", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (r *regProxy) NodeExpandVolume(ctx context.Context, req *csi.NodeExpandVolumeRequest) (*csi.NodeExpandVolumeResponse, error) {
	var resp csi.NodeExpandVolumeResponse
	if err := r.forwardUnaryToDriver(ctx, "/csi.v1.Node/NodeExpandVolume", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

/* ---------------- Identity forwarding ---------------- */

func (r *regProxy) GetPluginInfo(ctx context.Context, req *csi.GetPluginInfoRequest) (*csi.GetPluginInfoResponse, error) {
	var resp csi.GetPluginInfoResponse
	// Forward to the real driver socket to obtain supported versions and identity
	if err := r.forwardUnaryToDriver(ctx, "/csi.v1.Identity/GetPluginInfo", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (r *regProxy) GetPluginCapabilities(ctx context.Context, req *csi.GetPluginCapabilitiesRequest) (*csi.GetPluginCapabilitiesResponse, error) {
	var resp csi.GetPluginCapabilitiesResponse
	// Forward to the driver socket
	if err := r.forwardUnaryToDriver(ctx, "/csi.v1.Identity/GetPluginCapabilities", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (r *regProxy) Probe(ctx context.Context, req *csi.ProbeRequest) (*csi.ProbeResponse, error) {
	var resp csi.ProbeResponse
	// Forward probe to driver socket
	if err := r.forwardUnaryToDriver(ctx, "/csi.v1.Identity/Probe", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

/* ---------------- Plugin registration forwarding ---------------- */

func (r *regProxy) GetInfo(ctx context.Context, req *pluginregistration.InfoRequest) (*pluginregistration.PluginInfo, error) {
	// Serve a static PluginInfo so kubelet can register the CSI driver even if the
	// backend registrar is momentarily unavailable.
	// Ensure we advertise at least CSI v1.0.0 so kubelet validation succeeds.
	return &pluginregistration.PluginInfo{
		Type:              "CSIPlugin",
		Name:              "csi.spiffe.io",
		Endpoint:          "/var/lib/kubelet/plugins_registry/csi.spiffe.io-reg.sock",
		SupportedVersions: []string{"1.0.0"},
	}, nil
}

func (r *regProxy) NotifyRegistrationStatus(ctx context.Context, req *pluginregistration.RegistrationStatus) (*pluginregistration.RegistrationStatusResponse, error) {
	var resp pluginregistration.RegistrationStatusResponse
	if err := r.forwardUnary(ctx, "/pluginregistration.Registration/NotifyRegistrationStatus", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

/* ---------------- Backend dialer ---------------- */

func dialBackendWithRetry(target string, timeout time.Duration) (*grpc.ClientConn, error) {
	infinite := timeout == 0
	var deadline time.Time
	if !infinite {
		deadline = time.Now().Add(timeout)
	}

	for {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		conn, err := grpc.DialContext(ctx, target, grpc.WithInsecure(), grpc.WithBlock(), grpc.WithContextDialer(func(ctx context.Context, addr string) (net.Conn, error) {
			// gRPC passes the dial string through; strip unix:// prefix if present
			if len(addr) >= 7 && addr[:7] == "unix://" {
				addr = addr[7:]
			}
			return net.Dial("unix", addr)
		}))
		cancel()
		if err == nil {
			return conn, nil
		}
		if !infinite && time.Now().After(deadline) {
			return nil, fmt.Errorf("timeout dialing backend %s: %w", target, err)
		}
		log.Printf("dial backend %s failed: %v; retrying...", target, err)
		time.Sleep(500 * time.Millisecond)
	}
}

/* ---------------- main ---------------- */

func main() {
	_ = os.RemoveAll(listenSocket)

	l, err := net.Listen("unix", listenSocket)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", listenSocket, err)
	}
	defer l.Close()

	nodeID := os.Getenv("MY_NODE_NAME")
	if nodeID == "" {
		if h, err := os.Hostname(); err == nil {
			nodeID = h
		}
	}

	// Dial backend registrar socket (internal) target string
	backendTarget := backendSocket
	if !(len(backendTarget) >= 7 && backendTarget[:7] == "unix://") {
		backendTarget = "unix://" + backendTarget
	}
	log.Printf("reg-proxy: backend registrar target %s", backendTarget)

	// Driver socket target (directly talk to the CSI driver for Identity/Probe)
	driverTarget := "unix:///spiffe-csi/driver.sock"
	log.Printf("reg-proxy: driver socket target %s", driverTarget)

	// Create regProxy without blocking on backend connection
	r := &regProxy{
		backendTarget: backendTarget,
		driverTarget:  driverTarget,
		nodeID:        nodeID,
	}
	grpcServer := grpc.NewServer()

	// Register Node, Identity and PluginRegistration servers (NodeGetInfo handled locally)
	csi.RegisterNodeServer(grpcServer, r)
	csi.RegisterIdentityServer(grpcServer, r)
	pluginregistration.RegisterRegistrationServer(grpcServer, r)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	// Serve immediately (do not block on backend readiness)
	go func() {
		log.Printf("reg-proxy: serving host registration unix socket %s", listenSocket)
		if err := grpcServer.Serve(l); err != nil {
			log.Fatalf("grpc server exited: %v", err)
		}
	}()

	// Background connector (non-fatal). This will retry indefinitely.
	go func() {
		for {
			conn, err := r.ensureBackend()
			if err != nil {
				log.Printf("reg-proxy: background connector retrying after error: %v", err)
				time.Sleep(1 * time.Second)
				continue
			}
			log.Printf("reg-proxy: connected to backend registrar %s", backendTarget)
			// keep conn reference; ensureBackend already stored it
			_ = conn
			return
		}
	}()

	<-stop
	log.Printf("reg-proxy: shutting down")
	grpcServer.GracefulStop()

	// Close backend connection if one exists
	if v := r.backendConn.Load(); v != nil {
		if c := v.(*grpc.ClientConn); c != nil {
			_ = c.Close()
		}
	}
}
