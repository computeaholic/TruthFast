FROM kindest/node:v1.30.2

COPY .certs/ca.crt /usr/local/share/ca-certificates/threadforge-ca.crt

RUN update-ca-certificates
