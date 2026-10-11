# hpl-cloud

Stateless HTTPS endpoint for HP Lifestyle's opt-in anonymized cloud analysis. Go standard library only.

`POST /v1/analyze` takes `hpl.cloud_payload.v1` (≤ 16 KB) and returns `hpl.cloud_insights.v1`. No storage, no identity, outcome-only logs, TLS 1.3, iOS-format public-key pins (`hpl-cloud pin fullchain.pem`), optional App Attest assertion check.

```bash
go test -race ./...                       # uses ../Spec-shaped fixtures in ../Fixtures
go run ./cmd/hpl-cloud serve              # needs HPL_TLS_CERT + HPL_TLS_KEY (or HPL_PLAINTEXT=1 for local dev)
```

Design, contract, pinning, and deploy gaps: [`../docs/m8-cloud-endpoint.md`](../docs/m8-cloud-endpoint.md).
