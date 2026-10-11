# User-facing copy review against §13 (M7)

Reviewed 2026-10-11 against architecture §13: general-wellness framing, no diagnosis or treatment or risk language, no lab interpretation, honest privacy claims (FTC Act §5: say "de-identified and coarsened", never "anonymous"; never "HIPAA compliant"). *Not legal advice; a lawyer's review is still on the TestFlight checklist.*

## Automated guards (run in CI)

| Surface | Check |
|---|---|
| Generated notes (every engine) | `OutputGuard`: blocklist, dose pattern, numbers must trace to the input, evidence must resolve (M3) |
| Cloud results | Same `OutputGuard`, run against the sent payload (M6) |
| Consent copy (glasses, cloud), privacy, reminder, delete/export, cloud errors | `HPLUITests`: `OutputGuard.blocklistHits` empty, plus no "anonymous", "HIPAA", "FDA", "clinically", "guarantee" or "100%" |
| App Store / TestFlight text (`Metadata/app-store/en-US/*.txt`) | `scripts/check_store_copy.py`: the same blocklist parsed from `OutputGuard.swift`, plus store overclaims ("detect", "early warning", "prevent", "heart health", "certified", …), the disclaimer verbatim in the description, and length limits |
| Logs | `scripts/check_no_phi_logging.sh` |

## Manual review, by surface

| Surface | Verdict | Notes |
|---|---|---|
| Onboarding disclaimer (`Disclaimer.text`) | OK | Matches §13 v1 text exactly; must be acknowledged; also in Settings and in every note's footer. |
| Health connect screen | OK | "Read-only", "per-day totals", "nothing leaves this device" are all true in this build. |
| Today metrics | OK | Compared only with the user's own 28-day typical; the HRV caveat says not to compare with other people. |
| Notes and "Why am I seeing this?" | OK | Coaching tone; every number is cited; clinician prompts only restate a report flag. |
| Experiments | OK | Framed as self-experiments; the result is a baseline vs intervention comparison and no causal claim. |
| Labs | OK | "Values are shown as printed… doesn't interpret them"; ranges are labeled "Range on report"; critical-flag copy is fixed text. |
| Meals | OK | Calorie estimates are labeled as the companion's rough estimate. |
| Cloud analysis | OK | Uses "de-identified" and "coarsened", never "anonymous"; the re-identification risk is stated; the demo is labeled as on-device. |
| Privacy & your data | OK | Each line checked against the code: Data Protection Complete, no network outside HPLCloud (CI boundary check), backups disclosed. |
| Reminder notification | OK | Content-free ("Your daily notes are ready when you are."), so nothing sensitive shows on the lock screen. |
| Pairing sheet | Accepted | "Treat it like a password" contains the blocked substring "treat", but in a security context. Pairing copy is not run through the health blocklist. |
| App Store description, keywords, review notes | OK | Wellness framing, category Health & Fitness, the disclaimer verbatim, no claims about heart conditions. The icon has no ECG or pulse imagery. |

## Changed in M7

- Example-data banner: "SYNTHETIC FIXTURE: example data, not yours" became "EXAMPLE DATA: not yours" (plain language, same honesty).
- Lab import with no rows: removed milestone jargon ("Manual entry arrives later in M2") and replaced it with a practical tip.
- Health-access path: "Settings › Health › Data Access & Devices" became "Settings › Privacy & Security › Health › HP Lifestyle". **Verify on an iOS 26 device.**
- New copy (privacy, delete, export, reminders, consents, about) is covered by the tests above.

## Open

- Product name and trademark check (§12) before the App Store page is public.
- Lawyer review of the privacy policy and consent copy before external TestFlight.
- Screenshots: not produced yet. Use the example-data mode and keep the banner visible.
