#!/usr/bin/env python3
"""Reference producer for the HPL Glasses Bridge (docs/m5-glasses.md). Standard library only.

This is the contract a glasses companion implements (rayban-vlm-poc "Glance", VisionClaw, ...):

  pair     URI         -> prints pairing id + secret parsed from an hplpair://v1 URI (what the producer stores)
  glance   ENTRY.json  -> converts a Glance meal-log entry (phone/bridge-contract.json `inferResponse.entry`)
                          into an hpl.event.v1 `meal.logged` event (deterministic event_id, so re-exports dedupe)
  sign     EVENT.json… -> writes one hpl.signed_event.v1 line per event (an .hplevent file is JSON Lines)
  verify   FILE.hplevent -> verifies every line (exit 1 on any failure)

Signature: sig = hex(HMAC-SHA256(secret, "hpl.signed_event.v1\\n" + pairing_id + "\\n" + str(ts) + "\\n" + body)),
body = the exact UTF-8 event JSON string carried in the wrapper.
"""
import argparse
import base64
import datetime as dt
import hashlib
import hmac
import json
import sys
import urllib.parse

WRAPPER_SPEC = "hpl.signed_event.v1"
CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

# Test-only pairing used by Fixtures/signed. Never use outside fixtures.
FIXTURE_PAIRING_ID = "fixturepair00001"
FIXTURE_SECRET = bytes(range(1, 33))


def parse_pairing_uri(uri):
    u = urllib.parse.urlparse(uri)
    q = urllib.parse.parse_qs(u.query)
    if u.scheme != "hplpair" or u.netloc != "v1" or "id" not in q or "k" not in q:
        raise ValueError("expected hplpair://v1?id=<16 chars>&k=<base64url 32 bytes>")
    k = q["k"][0]
    secret = base64.urlsafe_b64decode(k + "=" * (-len(k) % 4))
    if len(secret) != 32:
        raise ValueError("secret must be 32 bytes")
    return q["id"][0], secret


def signing_input(pairing_id, ts, body):
    return f"{WRAPPER_SPEC}\n{pairing_id}\n{ts}\n{body}".encode("utf-8")


def sign(pairing_id, secret, ts, body):
    sig = hmac.new(secret, signing_input(pairing_id, ts, body), hashlib.sha256).hexdigest()
    return {"spec": WRAPPER_SPEC, "pairing_id": pairing_id, "ts": ts, "sig": sig, "body": body}


def verify(wrapper, pairing_id, secret):
    if wrapper.get("spec") != WRAPPER_SPEC or wrapper.get("pairing_id") != pairing_id:
        return False
    want = sign(pairing_id, secret, wrapper["ts"], wrapper["body"])["sig"]
    return hmac.compare_digest(want, wrapper.get("sig", ""))


def ulid(ms, entropy):
    """ULID from a millisecond timestamp and 10 bytes of entropy (Crockford base32, 26 chars)."""
    n = (ms << 80) | int.from_bytes(entropy[:10], "big")
    return "".join(CROCKFORD[(n >> (5 * i)) & 31] for i in reversed(range(26)))


def glance_entry_to_event(entry, tz, version):
    """Glance MealEntry -> hpl.event.v1 meal.logged. Drops frameId/rawJson: frames and raw VLM output stay in Glance."""
    ts = dt.datetime.fromisoformat(entry["ts"].replace("Z", "+00:00")).astimezone(dt.timezone.utc)
    ms = int(ts.timestamp() * 1000)
    seed = hashlib.sha256(f"glance|{ms}|{entry.get('frameId', '')}|{entry['name']}".encode()).digest()
    item = {"name": entry["name"].strip()[:80]}
    if entry.get("kcal") is not None:
        item["kcal_est"] = entry["kcal"]
    if entry.get("protein_g") is not None:
        item["protein_g"] = entry["protein_g"]
    return {
        "spec": "hpl.event.v1",
        "event_id": ulid(ms, seed),
        "type": "meal.logged",
        "occurred_at": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "tz": tz,
        "producer": {"name": "glance", "version": version, "processing": "on_device"},
        "payload": {"items": [item]},
    }


def compact(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("sign", "verify"):
        p = sub.add_parser(name)
        p.add_argument("files", nargs="+")
        p.add_argument("--pairing", help="hplpair://v1 URI (default: the test-only fixture pairing)")
        if name == "sign":
            p.add_argument("--ts", type=int, help="Unix seconds (default: now)")
    p = sub.add_parser("pair")
    p.add_argument("uri")
    p = sub.add_parser("glance")
    p.add_argument("entry")
    p.add_argument("--tz", default="America/Los_Angeles")
    p.add_argument("--version", default="0.0.0")
    a = ap.parse_args(argv)

    if a.cmd == "pair":
        pid, secret = parse_pairing_uri(a.uri)
        print(json.dumps({"pairing_id": pid, "secret_sha256": hashlib.sha256(secret).hexdigest()}))
        return 0
    if a.cmd == "glance":
        with open(a.entry, encoding="utf-8") as f:
            print(json.dumps(glance_entry_to_event(json.load(f), a.tz, a.version), indent=2, ensure_ascii=False))
        return 0
    pid, secret = parse_pairing_uri(a.pairing) if a.pairing else (FIXTURE_PAIRING_ID, FIXTURE_SECRET)
    if a.cmd == "sign":
        ts = a.ts if a.ts is not None else int(dt.datetime.now(dt.timezone.utc).timestamp())
        for path in a.files:
            with open(path, encoding="utf-8") as f:
                print(compact(sign(pid, secret, ts, compact(json.load(f)))))
        return 0
    bad = 0
    for path in a.files:
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                if line.strip():
                    ok = verify(json.loads(line), pid, secret)
                    bad += not ok
                    print(f"{'ok ' if ok else 'BAD'} {path}:{n}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
