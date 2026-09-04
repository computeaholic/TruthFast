# Build a small static binary and package into minimal image
FROM golang:1.20-alpine AS build
RUN apk add --no-cache git ca-certificates
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/csi-node-shim ./

FROM alpine:3.18
RUN apk add --no-cache ca-certificates
COPY --from=build /out/csi-node-shim /usr/local/bin/csi-node-shim
RUN chmod +x /usr/local/bin/csi-node-shim
ENTRYPOINT ["/usr/local/bin/csi-node-shim"]
