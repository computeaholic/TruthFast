# syntax=docker/dockerfile:1

FROM golang:1.25-alpine AS builder

WORKDIR /workspace

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=arm64

# Copy go module files first for caching
COPY go.mod go.sum ./
RUN go mod download

# Copy the controller source
COPY . .

RUN go build -o manager ./cmd/manager

FROM gcr.io/distroless/base-debian12

WORKDIR /

COPY --from=builder /workspace/manager /manager

USER 65532

ENTRYPOINT ["/manager"]