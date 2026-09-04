FROM golang:1.25-alpine AS build
RUN apk add --no-cache git ca-certificates
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/csi-node-reg-proxy ./

FROM alpine:3.18
RUN apk add --no-cache ca-certificates
COPY --from=build /out/csi-node-reg-proxy /usr/local/bin/csi-node-reg-proxy
RUN chmod +x /usr/local/bin/csi-node-reg-proxy
ENTRYPOINT ["/usr/local/bin/csi-node-reg-proxy"]
