package main

import (
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	"google.golang.org/grpc"

	csi "github.com/container-storage-interface/spec/lib/go/csi"
)

var (
	listenSocket  string
	backendSocket string
)

func init() {
	flag.StringVar(&listenSocket, "listen-socket", "/csi/csi.sock", "unix socket to listen on")
	// default backend socket is the driver plugin socket; can be overridden via env CSI_BACKEND_SOCKET
	flag.StringVar(&backendSocket, "backend-socket", "", "unix socket to forward to (overridden by CSI_BACKEND_SOCKET env if set)")
	flag.Parse()
}

func main() {
	// Remove previous socket if present
	if err := os.RemoveAll(listenSocket); err != nil {
		log.Fatalf("failed to remove socket %s: %v", listenSocket, err)
	}

	l, err := net.Listen("unix", listenSocket)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", listenSocket, err)
	}
	defer l.Close()

	// Resolve backend socket: env var CSI_BACKEND_SOCKET overrides flag. Default to driver plugin socket.
	backend := backendSocket
	if env := os.Getenv("CSI_BACKEND_SOCKET"); env != "" {
		backend = env
	}
	if backend == "" {
		backend = "/spiffe-csi/driver.sock"
	}
	// Ensure the address uses unix:// scheme for clarity in dialing
	if !(len(backend) >= 7 && backend[:7] == "unix://") {
		backend = "unix://" + backend
	}
	forwarder, err := NewForwarder(backend)
	if err != nil {
		log.Fatalf("failed to create forwarder: %v", err)
	}
	log.Printf("resolved backend socket to %s", backend)

	// Determine node id: prefer MY_NODE_NAME env var otherwise use host name
	nodeID := os.Getenv("MY_NODE_NAME")
	if nodeID == "" {
		h, err := os.Hostname()
		if err == nil {
			nodeID = h
		}
	}
	if nodeID == "" {
		log.Printf("warning: node ID empty; NodeGetInfo will fail until MY_NODE_NAME or hostname is set")
	}

	grpcServer := grpc.NewServer()

	csi.RegisterIdentityServer(grpcServer, &identityServer{})
	csi.RegisterNodeServer(grpcServer, &nodeServer{fwd: forwarder, nodeID: nodeID})

	// Graceful shutdown
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		log.Printf("serving unix socket %s", listenSocket)
		if err := grpcServer.Serve(l); err != nil {
			log.Fatalf("grpc server exited: %v", err)
		}
	}()

	<-stop
	log.Printf("shutting down")
	grpcServer.GracefulStop()
	forwarder.Close()
}
