FROM registry.threadforge.local:30500/mirror/docker.io/library/golang:1.22.12-alpine@sha256:1699c10032ca2582ec89a24a1312d986a3f094aed3d5c1147b19880afe40e052 AS builder

WORKDIR /src/platform/cmd/threadforge-notifier

ARG TARGETARCH=arm64

COPY platform/cmd/threadforge-notifier/go.mod ./go.mod
COPY platform/cmd/threadforge-notifier/main.go ./main.go

RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w -buildid=" -o /out/threadforge-notifier .

FROM registry.threadforge.local:30500/mirror/docker.io/library/alpine@sha256:d129f711e48e683b2e761f3a9297c3b9f7e5e96fb98ae7723bc6a88522f3c8a4

COPY --from=builder /out/threadforge-notifier /threadforge-notifier

USER 65532:65532
ENTRYPOINT ["/threadforge-notifier"]
