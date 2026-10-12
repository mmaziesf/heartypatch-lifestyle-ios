# Stateless HP Lifestyle cloud endpoint. Build from the server/ directory:
#   docker build -t hpl-cloud .
# Run with the TLS cert/key mounted read-only so TLS terminates in this process (keeps the pinned key end to end):
#   docker run -p 443:8443 -v /etc/hpl/tls:/tls:ro -e HPL_TLS_CERT=/tls/fullchain.pem -e HPL_TLS_KEY=/tls/privkey.pem \
#     --read-only --cap-drop ALL hpl-cloud
# On Fly.io (fly.toml + ../docs/deploy-fly.md) the same image runs unchanged: HPL_ADDR=:8443 comes from [env], and the
# cert/key arrive as the secrets HPL_TLS_CERT_PEM / HPL_TLS_KEY_PEM instead of mounted files.
FROM golang:1.24 AS build
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /hpl-cloud ./cmd/hpl-cloud

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /hpl-cloud /hpl-cloud
USER nonroot:nonroot
EXPOSE 8443
ENTRYPOINT ["/hpl-cloud", "serve"]
