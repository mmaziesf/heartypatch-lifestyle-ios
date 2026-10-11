# HeartyPatch Lifestyle: Architecture Summary (1 page)

**What it is:** A local-first iOS app that combines Apple Watch/HealthKit data and your uploaded blood work, plus Ray-Ban meal logs in Phase 2. From these it builds a daily summary on your phone and generates coaching-style lifestyle notes and N-of-1 experiments with an on-device model. You can opt in to an anonymized cloud tier for deeper multi-week analysis.

**What it isn't:** No diagnosis, treatment, supplement/drug dosing, or lab interpretation. Lab flags only repeat the range printed on your own report. No backend accounts, no third-party analytics, no HIPAA claims, no custom hardware (the original HeartyPatch ECG patch is out of scope).

**Architecture in one breath:** SwiftUI app → HealthSync (anchored queries + background delivery, stores daily aggregates only) + Document Ingest (PDFKit/Vision OCR → rules-based lab parser → **you confirm every value**) + Glasses Bridge (signed VisionClaw events) → encrypted local store → Daily Pipeline (rules engine + `DailySummary` JSON, ~800 tokens) → local LLM → output guard → recommendations with "why am I seeing this" evidence. The only way out to the cloud is through one `EgressGate`, which anonymizes the payload and shows you a preview first.

**On-device model:** Default is **Apple Foundation Models** (no download, guided structured output). Fallback is **MLX Swift with a pinned ~3–4B 4-bit model** for unsupported devices or if Apple's model refuses health prompts. If no model is available, a deterministic rules engine still works. The model sees only a structured summary JSON: no names, no documents, no locations.

**Anonymization:** Allowlist schema. Identifiers and free text are dropped. Dates become relative day indices, age goes to 5-year bands, weight to BMI bands, times are rounded to 30 minutes, and extreme values are clamped. Rare or sensitive labs are not sent by default. Minimum 28-day window, mostly weekly aggregates, no device or user IDs. The preview hash must match the sent hash. Honest note: longitudinal data can never be 100% anonymous, and the consent copy says so.

**Ray-Ban / VisionClaw:** VisionClaw owns the glasses and Gemini Live. HPL accepts versioned `hpl.event.v1` events (`meal.start/items/photo/end`, `voice.note`, `lifestyle.event`) signed with HMAC via a QR-code pairing. Transport starts as a shared-inbox file import, with App Intents if VisionClaw runs on the same phone and a relay only with end-to-end encryption. No photos by default. If photos are on, they expire after 7 days and photos with faces are dropped. Caveat: VisionClaw already sends frames and audio to Google's cloud.

**Security:** File Protection Complete, Keychain for secrets, optional Face ID lock, cert pinning, health values never logged (CI check), optional App Attest for the cloud endpoint.

**Milestones:**
- M0 repo + disclaimers + SwiftUI shell
- M1 HealthKit daily aggregates (matching the Health app)
- M2 lab import + confirm loop (≥90% row accuracy on 30+ redacted reports)
- M3 local LLM notes + eval harness
- M4 recommendation UI, history, experiments
- M5 Ray-Ban bridge
- M6 opt-in anonymized cloud
- M7 polish + TestFlight

**Compliance stance:** FDA general-wellness framing. Watch App Store guidelines 1.4.1 and 5.1.3, the FTC Health Breach Notification Rule, and the Washington My Health My Data Act. A short lawyer review before external TestFlight.

**Next coding step:** M0. Workspace with 9 Swift packages, CI, the two JSON schemas (`daily_summary.v1`, `event.v1`) with round-trip tests, the tab shell + disclaimer acknowledgement, and a rules-only engine showing one fixture recommendation end-to-end.

**Need from you:**
1. Where does VisionClaw run (phone, Mac, or server)?
2. Is an iOS 26 minimum OK?
3. Is the cloud tier needed for v1?
4. Can you share 10–30 redactable lab PDFs to use as test fixtures?

Full doc: `heartypatch-lifestyle-app-architecture.md`
