package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	csi "github.com/container-storage-interface/spec/lib/go/csi"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// Forwarder establishes a gRPC connection to an existing CSI Node endpoint
// and exposes methods that forward RPCs 1:1.
type Forwarder struct {
	addr string
	mu   sync.Mutex
	conn *grpc.ClientConn
	cli  csi.NodeClient
}

func NewForwarder(addr string) (*Forwarder, error) {
	f := &Forwarder{addr: addr}
	// lazy connect on first call
	return f, nil
}

func (f *Forwarder) dial(ctx context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.conn != nil {
		return nil
	}
	// Expect addr to be in form unix:///path/to/socket
	var socketPath string
	if len(f.addr) >= 7 && f.addr[:7] == "unix://" {
		socketPath = f.addr[7:]
	} else {
		socketPath = f.addr
	}
	// Use custom dialer for unix domain sockets
	dialer := func(ctx context.Context, addr string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socketPath)
	}
	ctxDial, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	conn, err := grpc.DialContext(ctxDial, f.addr, grpc.WithContextDialer(dialer), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return fmt.Errorf("dial backend %s: %w", f.addr, err)
	}
	f.conn = conn
	f.cli = csi.NewNodeClient(conn)
	return nil
}

func (f *Forwarder) Close() {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.conn != nil {
		f.conn.Close()
		f.conn = nil
	}
}

func (f *Forwarder) NodeGetInfo(ctx context.Context, req *csi.NodeGetInfoRequest) (*csi.NodeGetInfoResponse, error) {
	if err := f.dial(ctx); err != nil {
		log.Printf("forwarder: NodeGetInfo dial error: %v", err)
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	resp, err := f.cli.NodeGetInfo(ctx, req)
	if err != nil {
		log.Printf("forwarder: NodeGetInfo backend error: %v", err)
		return nil, err
	}
	log.Printf("forwarder: NodeGetInfo success: %+v", resp)
	return resp, nil
}

func (f *Forwarder) NodeGetCapabilities(ctx context.Context, req *csi.NodeGetCapabilitiesRequest) (*csi.NodeGetCapabilitiesResponse, error) {
	if err := f.dial(ctx); err != nil {
		log.Printf("forwarder: NodeGetCapabilities dial error: %v", err)
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	resp, err := f.cli.NodeGetCapabilities(ctx, req)
	if err != nil {
		log.Printf("forwarder: NodeGetCapabilities backend error: %v", err)
		return nil, err
	}
	log.Printf("forwarder: NodeGetCapabilities success")
	return resp, nil
}

func (f *Forwarder) NodePublishVolume(ctx context.Context, req *csi.NodePublishVolumeRequest) (*csi.NodePublishVolumeResponse, error) {
	if err := f.dial(ctx); err != nil {
		log.Printf("forwarder: NodePublishVolume dial error: %v", err)
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	resp, err := f.cli.NodePublishVolume(ctx, req)
	if err != nil {
		log.Printf("forwarder: NodePublishVolume backend error: %v", err)
		return nil, err
	}
	log.Printf("forwarder: NodePublishVolume success")
	return resp, nil
}

func (f *Forwarder) NodeUnpublishVolume(ctx context.Context, req *csi.NodeUnpublishVolumeRequest) (*csi.NodeUnpublishVolumeResponse, error) {
	if err := f.dial(ctx); err != nil {
		log.Printf("forwarder: NodeUnpublishVolume dial error: %v", err)
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	resp, err := f.cli.NodeUnpublishVolume(ctx, req)
	if err != nil {
		log.Printf("forwarder: NodeUnpublishVolume backend error: %v", err)
		return nil, err
	}
	log.Printf("forwarder: NodeUnpublishVolume success")
	return resp, nil
}

func (f *Forwarder) NodeStageVolume(ctx context.Context, req *csi.NodeStageVolumeRequest) (*csi.NodeStageVolumeResponse, error) {
	if err := f.dial(ctx); err != nil {
		log.Printf("forwarder: NodeStageVolume dial error: %v", err)
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	resp, err := f.cli.NodeStageVolume(ctx, req)
	if err != nil {
		log.Printf("forwarder: NodeStageVolume backend error: %v", err)
		return nil, err
	}
	log.Printf("forwarder: NodeStageVolume success")
	return resp, nil
}

func (f *Forwarder) NodeUnstageVolume(ctx context.Context, req *csi.NodeUnstageVolumeRequest) (*csi.NodeUnstageVolumeResponse, error) {
	if err := f.dial(ctx); err != nil {
		log.Printf("forwarder: NodeUnstageVolume dial error: %v", err)
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	resp, err := f.cli.NodeUnstageVolume(ctx, req)
	if err != nil {
		log.Printf("forwarder: NodeUnstageVolume backend error: %v", err)
		return nil, err
	}
	log.Printf("forwarder: NodeUnstageVolume success")
	return resp, nil
}

func (f *Forwarder) NodeGetVolumeStats(ctx context.Context, req *csi.NodeGetVolumeStatsRequest) (*csi.NodeGetVolumeStatsResponse, error) {
	if err := f.dial(ctx); err != nil {
		log.Printf("forwarder: NodeGetVolumeStats dial error: %v", err)
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	resp, err := f.cli.NodeGetVolumeStats(ctx, req)
	if err != nil {
		log.Printf("forwarder: NodeGetVolumeStats backend error: %v", err)
		return nil, err
	}
	log.Printf("forwarder: NodeGetVolumeStats success")
	return resp, nil
}

func (f *Forwarder) NodeExpandVolume(ctx context.Context, req *csi.NodeExpandVolumeRequest) (*csi.NodeExpandVolumeResponse, error) {
	if err := f.dial(ctx); err != nil {
		log.Printf("forwarder: NodeExpandVolume dial error: %v", err)
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	resp, err := f.cli.NodeExpandVolume(ctx, req)
	if err != nil {
		log.Printf("forwarder: NodeExpandVolume backend error: %v", err)
		return nil, err
	}
	log.Printf("forwarder: NodeExpandVolume success")
	return resp, nil
}
