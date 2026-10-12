# M8: real anonymized cloud endpoint

Status: **server built and tested; not deployed.** `server/` is a stateless Go service (`hpl-cloud`, standard library only) that accepts only `hpl.cloud_payload.v1` and returns `hpl.cloud_insights.v1`. The iOS app talks to it through the existing `HTTPSCloudTransport` (TLS 1.3, public-key pinned, ephemeral session) when a build sets `HPL_CLOUD_ENDPOINT` + `HPL_CLOUD_PINS`. Default builds still use the on-device demo analyzer, so nothing leaves the device until you configure an endpoint and ship that build.

Personal wellness only. The server returns the same observation/nudge shapes as the demo; the client still re-checks every insight with `OutputGuard`.

## Contract

```
POST /v1/analyze
  Content-Type: application/json
  X-HPL-Request-ID: <request_id from the body>           (must match; 400 otherwise)
  [X-HPL-Attest-Key-ID, X-HPL-Attest-Assertion]          (only when HPL_ATTEST=app-attest)
  body: hpl.cloud_payload.v1, compact JSON, ≤ 16 KB
→ 200 application/json hpl.cloud_insights.v1 (≤ 64 KB, same request_id, ≤ 5 insights, every evidence path resolves in the body)
→ 4xx/5xx {"error":"<fixed code>"}   (method, content_type, too_large, attest, schema, request_id, busy, analyzer, analyzer_output, panic)

GET /healthz → 200 "ok"
```

Error bodies are fixed codes; nothing from the request is echoed. Every response sets `Cache-Control: no-store`, `nosniff`, HSTS, `no-referrer`, and no cookies.

## What "accept the anonymized schema only" means here

`internal/api/payload.go` mirrors `Spec/hpl.cloud_payload.v1.schema.json` rule for rule, and is stricter where Go's JSON decoder is loose:

- unknown keys rejected (`DisallowUnknownFields`) **and** keys must match the exact lowercase spelling (Go matches keys case-insensitively, so `"Request_ID"` would otherwise slip through);
- duplicate keys rejected (Go keeps the last one silently: a smuggling vector);
- `null` anywhere, trailing data, non-object top level, nesting > 8, and bodies > 16 KB rejected;
- every enum, range, pattern, `multipleOf 5`, `uniqueItems`, and required field from the schema.

Tests use the repo's own fixtures: `Fixtures/cloud/payload-28d.synthetic.json` must decode, every `Fixtures/invalid/cloud-payload-*.json` must fail, plus ~28 targeted mutations (name, calendar date, food name, free-text tag, exact age, rare lab, lab name, uppercase UUID, …). A Go fuzz target runs in CI.

## Analyzer

`api.RulesAnalyzer` is a line-for-line port of the iOS `DemoCloudAnalyzer`. CI proves parity: the server's answer to the golden payload equals `Fixtures/cloud/insights-28d.synthetic.json` (the file the Swift tests generate). The `api.Analyzer` interface is where a real model goes later (see gaps). Rules for any analyzer: pure function of the payload, no storage, no logs of inputs/outputs, no forwarding to a third party. The handler validates analyzer output (envelope, request id, kinds, lengths, evidence that resolves in the sent bytes) and drops anything bad before replying.

## Stateless, and what the logs contain

- No database, disk, cache, cookies, sessions, or per-client rate limiting (that would need IP state). A global in-flight cap (`HPL_MAX_INFLIGHT`, default 32) returns 503 when saturated.
- Access log (JSON, stdout) per request: `route` (analyze/healthz/other), `status`, `class` (the fixed error code or ok), `ms`. Nothing else: no body, request id, IP, port, user agent, headers, App Attest key id, analyzer error text, or panic value.
- `http.Server.ErrorLog` is replaced by a fixed `http_server_error` event, because net/http writes TLS-handshake failures there **with the client's IP:port**.
- TLS 1.3 only, session tickets off (resumption can't link two requests).
- `server_test.go: TestLogsCarryNoRequestData` sends canaries in the body, User-Agent, Cookie, request id, and App Attest headers, triggers a failed TLS handshake, and asserts none of them (nor `127.0.0.1`) appear in the logs. That closes the M6 exit criterion "Endpoint logs contain no bodies" for this server. It cannot cover a hosting provider's own edge/LB logs (see deploy).

## App Attest hook

`internal/attest`: `Verifier` interface, called with **SHA-256 of the exact body before parsing**. On iOS that hash is also what the user approved on the preview screen, so the assertion's `clientDataHash` is the approved-preview hash.

- `HPL_ATTEST=off` (default): accept.
- `HPL_ATTEST=app-attest` + `HPL_APP_ID=TEAMID.com.hpl.lifestyle`: verifies an App Attest **assertion** per Apple's steps: CBOR `{signature, authenticatorData}`, nonce = SHA256(authData ‖ clientDataHash), ECDSA P-256 over SHA256(nonce) with the registered key, RP ID hash = SHA256(app id), counter strictly increasing (replay). Tested with generated keys: valid, replay, body swap, wrong app id, unknown key, foreign signature, garbage CBOR (+ fuzz).
- **Not built:** key registration (verifying the attestation object and its x5c chain to Apple's App Attestation Root CA against a server-issued challenge) and a persistent `KeyStore`. Today the store is in-memory and empty, so `app-attest` mode refuses everything. On iOS, `CloudAttestationProvider` + header plumbing exist in `HTTPSCloudTransport`, but no `DCAppAttestService` implementation yet.
- **Privacy trade-off to decide before turning it on:** an App Attest key id is stable per install, so requests from one install become linkable server-side (the payload still has no identity, and key ids are never logged). The unlinkable alternative is a separate token issuer: App Attest once → blind/Privacy-Pass-style tokens → analyze with a token only. Recommend: `off` for personal use; tokens before any public launch.

## Pinning

`HTTPSCloudTransport` pins `base64(SHA-256(SecKeyCopyExternalRepresentation(key)))` for any key in the server chain. That is **not** the usual SPKI/HPKP pin: for EC keys the hashed bytes are the raw X9.63 point (`04‖X‖Y`), for RSA the PKCS#1 DER. Use the bundled tool, which is tested against both formats and against a pinning TLS 1.3 client:

```bash
cd server && go build -o hpl-cloud ./cmd/hpl-cloud
./hpl-cloud pin /etc/letsencrypt/live/<host>/fullchain.pem   # prints one pin per cert, leaf first
```

The iOS check also requires normal trust evaluation to pass, so the certificate must be publicly trusted (e.g. Let's Encrypt). Pin-friendly setup:

- pin the **leaf key** and renew with the same key (`certbot renew --reuse-key`), plus a **backup pin** for a spare key generated now and kept offline; ship both in `HPL_CLOUD_PINS`;
- or pin the issuing intermediate's key (survives leaf rotation; weaker, and breaks when the CA rotates intermediates);
- **terminate TLS in `hpl-cloud` itself** (L4/TCP passthrough at any load balancer). A TLS-terminating CDN/proxy (Cloudflare, ALB with HTTPS listener) changes the presented key and sees plaintext bodies, which defeats both pinning and the "no bodies in logs" claim.

## iOS wiring

- `CloudEndpointConfig` (HPLCloud) reads Info.plist `HPLCloudEndpoint` / `HPLCloudPublicKeyPins`, which `project.yml` fills from build settings `HPL_CLOUD_ENDPOINT` / `HPL_CLOUD_PINS` (empty by default). It requires https, a host, no user/password/query/fragment, and ≥ 1 well-formed 32-byte base64 pin; otherwise `nil`.
- `CloudTransports.make(config:)` → `HTTPSCloudTransport` when configured, else `DemoCloudTransport`. The app uses `CloudTransports.fromMainBundle()`. Build-time only on purpose: no Settings field that a user could be talked into pointing elsewhere.
- Settings › Cloud analysis already shows "Remote service (https:host)" when the transport leaves the device; egress records get `leftDevice = true`.

```bash
xcodegen generate
xcodebuild … HPL_CLOUD_ENDPOINT=https://hpl.example.com/v1/analyze HPL_CLOUD_PINS="<leafPin>,<backupPin>"
```

## Run locally

```bash
cd server
go test -race ./...
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout key.pem -out cert.pem -days 7 \
  -subj /CN=localhost -addext subjectAltName=DNS:localhost
HPL_ADDR=127.0.0.1:8443 HPL_TLS_CERT=cert.pem HPL_TLS_KEY=key.pem go run ./cmd/hpl-cloud serve
python3 -c "import json;print(json.dumps(json.load(open('../Fixtures/cloud/payload-28d.synthetic.json')),separators=(',',':')))" > /tmp/body.json
curl --tlsv1.3 --cacert cert.pem https://localhost:8443/v1/analyze -H 'Content-Type: application/json' \
  -H 'X-HPL-Request-ID: 00000000-0000-4000-8000-000000000001' --data-binary @/tmp/body.json
```

(A self-signed cert works for curl and the Go tests, not for the iPhone, whose pin check also requires system trust.)

## Deploy gaps (nothing is deployed)

1. **Host + domain + public cert.** Needs a VM or container host with TCP passthrough (e.g. a small VPS, Fly.io with raw TCP/`tls` handler off, or a GCP/AWS VM with an L4 LB), a DNS name, Let's Encrypt with `--reuse-key`, and a backup key. `server/Dockerfile` builds a distroless nonroot image. **Fly.io packaging now exists:** `server/fly.toml` + [`deploy-fly.md`](deploy-fly.md) (still not deployed).
2. **Provider logs.** The process logs nothing identifying, but cloud LBs, firewalls, and VPC flow logs record client IPs by default. Turn those off or set short retention; document it in the privacy policy.
3. **Real analysis model.** Only the rules analyzer exists. An LLM analyzer should run on the same host (e.g. a local open-weights model behind the `Analyzer` interface), not forward payloads to a third-party API, and keep the evidence-path contract.
4. **App Attest registration + key store**, and the on-device `DCAppAttestService` provider (see trade-off above). Abuse control is otherwise only the global in-flight cap.
5. **Shipping copy before an endpoint build goes to anyone:** `PrivacyCopy` ("In this version it runs on this iPhone"), `Views.swift` ("Nothing leaves this device."), `App/PrivacyInfo.xcprivacy` (declare Health & Fitness data, not linked, not tracking), App Store privacy labels, `Metadata/app-store/en-US/description.txt` + `review_notes.txt`, and `docs/privacy-policy.md`. These are all still true for default builds, so they were not changed.
6. **Live pin test from iOS.** The pin format is verified server-side (Go) and against Apple's documented `SecKeyCopyExternalRepresentation` layout; it has not been exercised by `HTTPSCloudTransport` against a deployed host yet.

## Cloud build configuration

`project.yml` defines a third Xcode configuration, **Cloud** (Release-based), and scheme
**HeartyPatchLifestyle-Cloud**. Only Cloud sets `HPL_CLOUD_ENDPOINT=https://heartypatch.app/v1/analyze`
and `HPL_CLOUD_PINS` (leaf + intermediate). Debug/Release keep both empty, so default builds stay on-device.

Select it: `xcodegen generate`, then pick the **HeartyPatchLifestyle-Cloud** scheme in Xcode
(or `xcodebuild -scheme HeartyPatchLifestyle-Cloud -configuration Cloud`).
After a cert rotation without `--reuse-key`, regenerate pins with `hpl-cloud pin fullchain.pem` and update `project.yml`.
