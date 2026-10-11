# M3: Local LLM lifestyle notes (scaffold)

General wellness notes only. No engine diagnoses, names conditions, mentions medications, supplements or doses, or interprets lab values. The disclaimer copy is unchanged.

## Flow (`DailyPipeline.runDetailed`)

1. **Build the summary.** `SummaryBuilder` produces a `DailySummaryV1` from HealthKit aggregates and confirmed labs.
2. **Run the rules.** `RulesEngine` has 13 deterministic rules (the M3 criterion is ≥ 10). Rules are listed in priority order. Every threshold compares the user with their own 28-day baseline; none is a clinical cut-off.
   - Clinician prompt: the report printed HH/LL.
   - Low completeness.
   - Short sleep, low HRV, late meal with alcohol.
   - Resting HR above baseline.
   - Low deep sleep, bedtime after midnight.
   - Hard workout.
   - Low steps, no exercise, high steps.
   - Experiment in progress.
3. **Clinician prompts are split off first.** `CLINICIAN_PROMPT_*` hits are rendered from fixed copy and always shown first. They never go to an LLM, and the guard rejects any clinician-kind note whose text isn't that fixed copy.
4. **Pick the engine.** `InsightEngines.preferred()` returns the Apple Foundation Models engine where the SDK has it. Availability is re-checked on every run (device eligible, Apple Intelligence on, model downloaded).
   - If the engine is unavailable, or throws (schema-invalid output, guardrail refusal, context overflow), the run falls back to `RulesOnlyEngine`.
5. **Build the prompt (`InsightPrompt`, `notes-v1`).** The prompt has fixed instructions plus a sanitized summary.
   - `PromptSanitizer` is fail-closed. It keeps only allow-listed keys and drops `provenance` and `rule_hits`.
   - Strings are cut to 40 plain ASCII characters, so no braces, quotes or newlines get through.
   - The model gets no names, documents, lab names, locations or raw samples.
   - Rule-hit ids are passed separately, with clinician hits removed.
6. **Structured output (`NotesOutputV1`).** The model returns 0 to 3 notes. Each note has a kind (observation, nudge or experiment), a title, a body and evidence field paths.
   - Experiment notes must carry an N-of-1 proposal: one behaviour change, 7 or 14 days, and one numeric summary metric to compare.
   - Foundation Models fills this through guided generation (`@Generable FMNotes`). Text engines return JSON. Both go through the same validator.
7. **`OutputGuard` (deterministic).** Checks every note:
   - Blocklist (diagnosis, disease, drug, supplement, interpretation terms) and dose patterns.
   - Evidence paths must resolve.
   - Every number must trace to the input (± rounding; 7/14/28 allowed as window lengths).
   - Experiment checks: allowed duration, numeric metric, no numbers or blocked terms in the intervention.
   - Clinician copy must be the fixed text.
8. **Rewrite or drop.** A note that fails only on numbers is replaced by the matching rule template and marked `rewritten`. Any other failure drops the note. At most 3 notes per day.
9. **Run report.** `Report` records the engine used, the fallback reason, every draft with its verdict, and latency. It stays on the device.

## Eval harness

`EvalHarness` + `EvalFixtures` run the pipeline over 50 synthetic days and score the M3 exit criteria.

- The 50 days are deterministic and seeded, and they cycle through 10 scenarios. 7 include an HH lab flag, and 10 include meal labels that try to inject instructions.
- The harness scores:
  - Schema-valid rate.
  - Blocklist hits in the final output.
  - Numeric traceability of the engine's own drafts, measured before the guard.
  - Notes per day.
  - Whether clinician prompts are shown first.
  - Median and p90 latency.

| Engine (CI, Linux/macOS) | Schema-valid | Final blocklist hits | Draft numbers traceable | Clinician first | Gate |
|---|---|---|---|---|---|
| Rules only | 50/50 | 0 | 160/160 | 7/7 | PASS |
| Mock "careful" LLM (copies numbers, proposes experiments) | 50/50 | 0 | 65/65 | 7/7 | PASS |
| Mock "sloppy" LLM (invents arithmetic, parrots meal labels) | 50/50 | 0 | 20/110 | 7/7 | **FAIL** (as intended). 65 drafts blocked, 55 rewritten; shipped output still clean |
| Mock "broken" LLM (prose, no JSON) | 0/50 | 0 | n/a (rules fallback) | 7/7 | **FAIL** (as intended). All 50 days fell back to rules |

The mock engines (`ScriptedInsightEngine`) get the real instructions and prompt. That's how the Foundation Models paths are tested on Linux CI without Apple Intelligence.

## Done

- `InsightEngine` protocol and its error taxonomy.
- `RulesOnlyEngine` with a template for every rule, plus experiment proposals.
- `FoundationModelsEngine`, compiled for iOS 26 / macOS 26 under `canImport(FoundationModels)`. It covers availability mapping, a single-turn session per day, greedy sampling and guided generation.
- Prompt contract and sanitizer.
- Output schema and validator.
- Guard upgrades.
- Pipeline: fallback, rewrite, clinician bypass and report.
- Eval harness with 50 fixtures and the gate.
- App wiring:
  - Settings shows the engine status (for example "Rules only: Apple Intelligence is turned off").
  - Today cards show the experiment proposal.
  - A DEBUG-only Settings section runs the eval on the device and shows gate, traceability and latency.

## Needs a device with Apple Intelligence

- **Real Foundation Models output has not been generated yet.** CI runners have no Apple Intelligence. `foundationModelsEval` runs only where the model is available and writes `hpl-eval-apple-foundation-models.json` to the temp directory.
  - Run it on an eligible iPhone (and/or Mac) from Xcode, or use the DEBUG eval button.
- **M3 exit criteria still open:**
  - The gate measured on FM output.
  - Median latency recorded on 2 devices.
  - Refusal and guardrail rate on health-adjacent prompts (architecture §6.1 risk: UNKNOWN).
- Context size and token count: the prompt's size estimate is about 4 characters per token. Check it against `SystemLanguageModel.default.contextSize` and `tokenCount(for:)` on a device.
- How Foundation Models behaves with optional nested `@Generable` fields (the experiment field), and the 7/14 snap of `durationDays`.

## Not built yet

- MLX fallback engine (architecture §6.2): pinned 3–4B model, on-demand download.
- Prompt and engine A/B tracking across OS model updates.
- Weekly 7-day reduced prompt.
- Persisting recommendations and feedback (M4).
- Starting and tracking experiments from a note (M4).
