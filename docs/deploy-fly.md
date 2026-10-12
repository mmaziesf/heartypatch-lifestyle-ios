# Deploy hpl-cloud on Fly.io

Personal deployment of the anonymized cloud endpoint (`server/`, see [m8-cloud-endpoint.md](m8-cloud-endpoint.md)).
Default app builds stay fully on-device; only a build with `HPL_CLOUD_ENDPOINT` + `HPL_CLOUD_PINS` set ever talks to this.

**Shape:** iPhone → TLS 1.3 → Fly edge (raw TCP passthrough, never decrypts) → `hpl-cloud` in a Fly Machine, which
terminates TLS with **your** Let's Encrypt key. The iOS app pins that key, so a proxy that re-terminates TLS fails closed.

**You need:** a Fly account with a card on file, a domain whose DNS you control (e.g. `hpl.example.com`), and on the Mac:
Homebrew, Go (for `hpl-cloud pin`), certbot, openssl (built in).

**Cost (check fly.io/pricing):** dedicated IPv4 is a paid monthly add-on (low single-digit $/month); one
`shared-cpu-1x` 256 MB machine that auto-stops when idle costs cents to a couple of dollars a month.

**What `*.fly.dev` can't do:** you can't get a Let's Encrypt cert for `*.fly.dev` (you don't control its DNS), and
Fly's own certificates terminate at the edge (breaks pinning). So a custom domain is required.

Throughout: replace `hpl-lifestyle-cloud` with your app name (Fly names are global) and `hpl.example.com` with your host.

---

## 1. Install and log in

```bash
brew install flyctl certbot go
git clone https://github.com/mmaziesf/heartypatch-lifestyle-ios && cd heartypatch-lifestyle-ios/server
fly auth login
```

If the app name is taken, edit `app = ...` in `server/fly.toml` to match whatever you create next.

## 2. Create the app and a dedicated IPv4

```bash
fly apps create hpl-lifestyle-cloud
fly ips allocate-v4 -a hpl-lifestyle-cloud      # DEDICATED (no --shared). Confirms the monthly charge.
fly ips allocate-v6 -a hpl-lifestyle-cloud      # free
fly ips list -a hpl-lifestyle-cloud             # note the v4 and v6 addresses
```

Why dedicated: `fly.toml` exposes 443 as a plain TCP service (`handlers = []`). Fly's shared IPv4 routes by TLS SNI /
HTTP Host, which only works with Fly's TLS/HTTP handlers, i.e. with Fly terminating TLS. Passthrough needs an IP that
belongs only to this app. Allocate it **before** the first `fly deploy` so Fly doesn't add a shared v4.

Do **not** run `fly certs add`: that makes Fly issue and serve its own cert at the edge.

## 3. DNS

At your DNS provider:

| Type | Name | Value |
|---|---|---|
| A | `hpl` | the dedicated IPv4 |
| AAAA | `hpl` | the IPv6 |

If the DNS is on Cloudflare: **DNS only (grey cloud)**. The orange-cloud proxy terminates TLS and breaks pinning.

## 4. Let's Encrypt cert with a reusable key (DNS-01, on your Mac)

The pin is a hash of the leaf **key**. Renewing with the same key (`--reuse-key`) keeps the pin valid forever; a new
key would brick every installed build until you ship new pins. DNS-01 means you don't need anything listening on port 80.

```bash
mkdir -p ~/hpl-tls && chmod 700 ~/hpl-tls
certbot certonly --manual --preferred-challenges dns \
  -d hpl.example.com --cert-name hpl \
  --key-type ecdsa --elliptic-curve secp256r1 --reuse-key \
  --config-dir ~/hpl-tls/config --work-dir ~/hpl-tls/work --logs-dir ~/hpl-tls/logs
```

certbot prints a TXT record (`_acme-challenge.hpl`); add it at your DNS provider, wait until
`dig +short TXT _acme-challenge.hpl.example.com` shows it, then press Enter. Result:

- `~/hpl-tls/config/live/hpl/fullchain.pem` (leaf + intermediate)
- `~/hpl-tls/config/live/hpl/privkey.pem` (the key you pin; never commit or share it)

**Automated alternative:** if your DNS provider has an API (Cloudflare, Route 53, …) use
[lego](https://go-acme.github.io/lego/) (`brew install lego`): `lego --dns cloudflare --domains hpl.example.com
--key-type ec256 --path ~/hpl-tls/lego run`, later `... renew --reuse-key`. Same files, no manual TXT step.

**Alternative: certbot on a VPS** you already run works the same; copy the two PEM files to the Mac over SSH and
continue at step 6. Keep the key off shared machines.

## 5. Backup key (do this once, now)

If the main key ever leaks or is lost, you need a second key the shipped app already trusts.

```bash
openssl ecparam -name prime256v1 -genkey -noout -out ~/hpl-tls/backup-key.pem && chmod 600 ~/hpl-tls/backup-key.pem
openssl req -new -x509 -key ~/hpl-tls/backup-key.pem -subj /CN=hpl-backup -days 1 -out ~/hpl-tls/backup-pin-only.pem
```

Move `backup-key.pem` somewhere offline (password manager / encrypted USB). To use it later:
`openssl req -new -key backup-key.pem -subj /CN=hpl.example.com -out backup.csr` then
`certbot certonly --manual --preferred-challenges dns --csr backup.csr ...`.

## 6. Pins

From `server/`:

```bash
go run ./cmd/hpl-cloud pin ~/hpl-tls/config/live/hpl/fullchain.pem   # line "0 ..." is the LEAF pin
go run ./cmd/hpl-cloud pin ~/hpl-tls/backup-pin-only.pem             # line "0 ..." is the BACKUP pin
```

These are **not** openssl/HPKP SPKI pins; they match iOS `SecKeyCopyExternalRepresentation`. Always use this tool.
`HPL_CLOUD_PINS = "<leafPin>,<backupPin>"`.

## 7. Load the cert into Fly as secrets

Fly has no host bind mounts, and the image is distroless (no shell to unpack files), so `hpl-cloud` reads the PEM
straight from env vars `HPL_TLS_CERT_PEM` / `HPL_TLS_KEY_PEM` (the file-based `HPL_TLS_CERT` / `HPL_TLS_KEY` are for
Docker/VPS; set one pair, never both, or the server refuses to start).

```bash
fly secrets set -a hpl-lifestyle-cloud --stage \
  HPL_TLS_CERT_PEM="$(cat ~/hpl-tls/config/live/hpl/fullchain.pem)" \
  HPL_TLS_KEY_PEM="$(cat ~/hpl-tls/config/live/hpl/privkey.pem)"
```

`--stage` stores them without restarting (nothing is deployed yet). `$(cat …)` keeps the key out of shell history.
`HPL_ADDR=:8443` and `HPL_ATTEST=off` are already in `fly.toml [env]`; no other secrets are needed.

## 8. Deploy

```bash
fly deploy -a hpl-lifestyle-cloud --ha=false     # one machine; builds server/Dockerfile remotely
fly logs -a hpl-lifestyle-cloud                  # expect: "listening" ... "tls":true,"attest":"off"
```

Expected noise: one `http_server_error` warn per minute with no fields, from Fly's TCP health check opening and closing
a connection without a TLS handshake.

## 9. Verify passthrough + pin before touching iOS

```bash
# The key the live host presents must equal your leaf pin. If it differs, something is terminating TLS in front.
echo | openssl s_client -connect hpl.example.com:443 -servername hpl.example.com -showcerts 2>/dev/null \
  | go run ./cmd/hpl-cloud pin /dev/stdin

# Real request with the synthetic fixture (expect 200 + hpl.cloud_insights.v1 JSON)
python3 -c "import json;print(json.dumps(json.load(open('../Fixtures/cloud/payload-28d.synthetic.json')),separators=(',',':')))" > /tmp/body.json
curl --tlsv1.3 https://hpl.example.com/v1/analyze -H 'Content-Type: application/json' \
  -H "X-HPL-Request-ID: $(uuidgen | tr A-Z a-z)" --data-binary @/tmp/body.json
```

First request after idle may take 1–2 s (auto-stop machine waking).

## 10. Point the iOS build at it

In `project.yml` (`settings.base`) or on the xcodebuild command line:

```bash
xcodegen generate
xcodebuild … HPL_CLOUD_ENDPOINT=https://hpl.example.com/v1/analyze HPL_CLOUD_PINS="<leafPin>,<backupPin>"
```

Settings › Cloud analysis should then say "Remote service (https:hpl.example.com)". Before any build with these set
goes to anyone but you, update the "runs on this iPhone" copy listed in m8-cloud-endpoint.md › Deploy gaps #5.

## Renewal (every ~60 days; Let's Encrypt certs are short-lived)

```bash
certbot certonly --manual --preferred-challenges dns -d hpl.example.com --cert-name hpl \
  --key-type ecdsa --elliptic-curve secp256r1 --reuse-key \
  --config-dir ~/hpl-tls/config --work-dir ~/hpl-tls/work --logs-dir ~/hpl-tls/logs   # choose "renew"
go run ./cmd/hpl-cloud pin ~/hpl-tls/config/live/hpl/fullchain.pem    # leaf pin MUST be unchanged
fly secrets set -a hpl-lifestyle-cloud \
  HPL_TLS_CERT_PEM="$(cat ~/hpl-tls/config/live/hpl/fullchain.pem)" \
  HPL_TLS_KEY_PEM="$(cat ~/hpl-tls/config/live/hpl/privkey.pem)"       # restarts the machine with the new cert
```

If the leaf pin changed, stop: don't deploy; re-run with `--reuse-key` (the old key is in `~/hpl-tls/config/archive/hpl/`).
An expired cert fails iOS trust evaluation even with a matching pin, so put a calendar reminder in.

---

## Logs and IPs: what this does and doesn't protect

Honest version:

- **hpl-cloud** logs only `{route, status, class, ms}`: no bodies, no IPs, no headers. With TCP passthrough and no
  `proxy_proto_options`, the process never even learns the client IP.
- **Fly's edge proxy sees and records your IP.** Every connection lands on Fly's proxy, which sees source IP/port,
  timing, bytes, and the SNI hostname. Fly keeps proxy/infra logs and metrics for operations and abuse handling under
  its own retention and privacy policy. **You cannot turn that off** on Fly. It sees no request bodies (passthrough).
- **Fly's log service keeps app stdout** (`fly logs`, log search) under Fly's retention. Ours contains nothing
  identifying, but don't add debug logging. Don't configure a log shipper unless you need one.
- **Fly holds your TLS private key** (encrypted secret, decrypted into the machine at boot) and runs your process.
  Passthrough protects against the proxy reading traffic; it does not protect against the host operator. Same is true
  of any VPS/cloud VM.
- **Re-identification is never zero**: an IP + timestamp + an anonymized 28-day summary sent from the same phone is
  linkable by whoever holds the IP logs. For a personal endpoint that's you and Fly.

To minimise: keep the app on `HPL_ATTEST=off`, single machine, no log shipping, no metrics exporters, don't
`fly ssh console` and `env` (it prints the key). If the edge IP log is unacceptable, the next step is a VPS where you
control the firewall (provider netflow still exists) or sending only over a VPN/relay you run.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `fly deploy` allocated a shared IPv4 | Release it (`fly ips release <ip>`), keep the dedicated one |
| curl: connection refused / reset on 443 | No dedicated IPv4, or DNS pointing at a shared/other IP |
| Pin from step 9 ≠ leaf pin | TLS terminated in front (Cloudflare orange cloud, `fly certs`, `tls` handler) or stale secret |
| Machine exits: "set either … not both" | Both file and inline TLS vars set; unset one pair |
| Machine exits: "load TLS certificate" | PEM mangled; re-run step 7 with `$(cat …)` exactly |
| iOS: request never leaves device | Endpoint/pins empty or malformed in the build (`CloudEndpointConfig` returns nil) |
