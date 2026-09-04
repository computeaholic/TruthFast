package main

import (
	"context"
	"fmt"
	"log"

	csi "github.com/container-storage-interface/spec/lib/go/csi"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// nodeServer implements csi.NodeServer and forwards selected RPCs to a backend driver
type nodeServer struct {
	fwd    *Forwarder
	nodeID string
}

func (n *nodeServer) NodeGetInfo(ctx context.Context, req *csi.NodeGetInfoRequest) (*csi.NodeGetInfoResponse, error) {
	// Provide a stable NodeGetInfo from the shim itself. Do not forward to the driver.
	log.Printf("nodeServer: NodeGetInfo called, returning nodeID=%s", n.nodeID)
	if n.nodeID == "" {
		return nil, status.Error(codes.Internal, "node id unavailable")
	}
	return &csi.NodeGetInfoResponse{NodeId: n.nodeID}, nil
}

func (n *nodeServer) NodePublishVolume(ctx context.Context, req *csi.NodePublishVolumeRequest) (*csi.NodePublishVolumeResponse, error) {
	// Forward NodePublishVolume to backend driver
	resp, err := n.fwd.NodePublishVolume(ctx, req)
	if err != nil {
		return nil, wrapErr("NodePublishVolume", err)
	}
	return resp, nil
}

func (n *nodeServer) NodeUnpublishVolume(ctx context.Context, req *csi.NodeUnpublishVolumeRequest) (*csi.NodeUnpublishVolumeResponse, error) {
	resp, err := n.fwd.NodeUnpublishVolume(ctx, req)
	if err != nil {
		return nil, wrapErr("NodeUnpublishVolume", err)
	}
	return resp, nil
}

// The NodeServer interface has several other methods — implement minimal stubs returning Unimplemented
func (n *nodeServer) NodeStageVolume(ctx context.Context, req *csi.NodeStageVolumeRequest) (*csi.NodeStageVolumeResponse, error) {
	// Forward if backend implements it, otherwise surface Unimplemented from backend
	if n.fwd == nil {
		return nil, status.Error(codes.Unimplemented, "NodeStageVolume not available (no backend)")
	}
	resp, err := n.fwd.NodeStageVolume(ctx, req)
	if err != nil {
		return nil, wrapErr("NodeStageVolume", err)
	}
	return resp, nil
}

func (n *nodeServer) NodeUnstageVolume(ctx context.Context, req *csi.NodeUnstageVolumeRequest) (*csi.NodeUnstageVolumeResponse, error) {
	if n.fwd == nil {
		return nil, status.Error(codes.Unimplemented, "NodeUnstageVolume not available (no backend)")
	}
	resp, err := n.fwd.NodeUnstageVolume(ctx, req)
	if err != nil {
		return nil, wrapErr("NodeUnstageVolume", err)
	}
	return resp, nil
}

func (n *nodeServer) NodeGetVolumeStats(ctx context.Context, req *csi.NodeGetVolumeStatsRequest) (*csi.NodeGetVolumeStatsResponse, error) {
	if n.fwd == nil {
		return nil, status.Error(codes.Unimplemented, "NodeGetVolumeStats not available (no backend)")
	}
	resp, err := n.fwd.NodeGetVolumeStats(ctx, req)
	if err != nil {
		return nil, wrapErr("NodeGetVolumeStats", err)
	}
	return resp, nil
}

func (n *nodeServer) NodeExpandVolume(ctx context.Context, req *csi.NodeExpandVolumeRequest) (*csi.NodeExpandVolumeResponse, error) {
	if n.fwd == nil {
		return nil, status.Error(codes.Unimplemented, "NodeExpandVolume not available (no backend)")
	}
	resp, err := n.fwd.NodeExpandVolume(ctx, req)
	if err != nil {
		return nil, wrapErr("NodeExpandVolume", err)
	}
	return resp, nil
}

func (n *nodeServer) NodeGetCapabilities(ctx context.Context, req *csi.NodeGetCapabilitiesRequest) (*csi.NodeGetCapabilitiesResponse, error) {
	// Return a minimal capability set from the shim to avoid backend Node service dependency.
	log.Printf("nodeServer: NodeGetCapabilities called")
	return &csi.NodeGetCapabilitiesResponse{}, nil
}

var _ csi.NodeServer = (*nodeServer)(nil)

// Small helper used to surface unexpected errors
func wrapErr(op string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%s: %w", op, err)
}
