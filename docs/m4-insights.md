# M4: Notes UI, history, and N-of-1 experiments

General wellness only. Notes and experiment results restate your own numbers against your own baseline. Nothing here diagnoses, treats, or interprets lab values. The disclaimer copy is unchanged and is shown in full in every "Why am I seeing this?" view.

## What the user can do

- **Today → Today's notes.** Each note card has these actions:
  - **Start N-day experiment** (experiment notes; one experiment at a time).
  - **Got it** (accept).
  - **Dismiss**.
  - **⋯ → Snooze until tomorrow / Helpful / Not helpful**.
  - Clinician prompts can be dismissed but not snoozed. They are never de-prioritized.
- **Why am I seeing this?** (`EvidenceView`) shows:
  - Every cited value from that day's summary, with a plain label, unit and field path.
  - The experiment idea (change, length, compared metric, how the comparison works).
  - Who wrote it: fixed templates, Apple's on-device model, or a downloaded model.
  - What the safety rules did: passed, or rewritten from a template because the model used a number not in the data. Clinician prompts are explained as fixed wording.
  - The full disclaimer.
- **Today → Your experiment.** Shows day X of N with a progress bar, **Did it today / Skipped today** check-ins, and **Stop experiment**.
- **Insights tab:**
  - The running experiment.
  - Finished experiments with their result.
  - Note history grouped by day, filterable by All / Accepted / Dismissed / Snoozed. Each note opens its evidence view.
  - **Export JSON** (`hpl.insights_export.v1`) through the system file exporter. Nothing is exported automatically.

## How it works

| Piece | Where | What it does |
|---|---|---|
| `StoredNote`, `NoteStatus`, `NoteFeedback`, `Experiment`, `ExperimentResult`, `InsightsRepository`, `InsightsExportV1`, `FieldLabels` | HPLCore | Models (architecture §4.2) |
| `InMemoryInsightsRepository`, `SwiftDataInsightsRepository` (`StoredNoteRecord`, `ExperimentRecord`) | HPLStore | Same contract test for both; the SwiftData store sits in the protected `Application Support/HPL` directory |
| `NoteLedger` | HPLPipeline | Records each day's run, keeps statuses, builds the next run's `PipelineContext`, exports |
| `PipelineContext` | HPLPipeline | Applied before the 3-note cap. Dismissed topics go last for 7 days. Snoozed topics are hidden until the snooze ends. The running experiment's topic is hidden. Clinician prompts are never affected |
| `ExperimentTracker`, `SummaryMetricSource` | HPLPipeline | Start, check in, progress, stop, finish due, and the result |
| `InsightsModel` | HPLUI | Observable state and actions for Today and Insights |
| `NoteCard`, `EvidenceView`, `ExperimentCard`, `InsightsView` | HPLUI (SwiftUI) | Views |

Decisions:

- **Topic** is the note's first evidence path with array indices removed (for example `sleep.total_min` or `meals.t_local`). A rule template and an LLM note about the same signal share one topic, so a dismissal applies to both.
- **Re-runs don't duplicate history.** The same topic on the same day keeps its id and status.
  - Notes the user hasn't touched take the newer text, and drop out if the new run no longer produces them.
  - Notes the user acted on stay as they were seen.
- **Experiments start today (day 1) and run N days, with N = 7 or 14 from the note.**
  - The baseline is the N days before the start, read from data that is already stored. Nobody has to wait two weeks before the experiment begins.
  - Only one experiment runs at a time.
  - Experiments complete automatically on the first run after the last day.
- **The result** gives the mean before vs during, the number of days with data, and the self-reported check-ins.
  - It also says whether the difference is within or beyond the usual day-to-day spread, measured as the baseline sample SD.
  - It always ends with "One run on one person is a hint, not proof."
  - "Not enough data" is reported when either window has fewer than max(3, ⌈N/2⌉) days with data.
  - There is no significance testing and no health interpretation.
  - Result copy is tested against the output-guard blocklist.
- **The metric comes from the same DailySummary path the note cited** (`SummaryMetricSource`), so "total sleep" means the same thing in the note, the experiment and the result.
- **Synthetic fixture mode** (Apple Health not connected) uses a throwaway in-memory store. Example actions work, but they never reach real history or the export.

## M4 exit criteria (architecture §11)

| Criterion | Status |
|---|---|
| Start a 14-day experiment from a recommendation, see progress daily, get a baseline-vs-intervention result | **Done in code + tests.** End-to-end test over stored HealthKit-shaped aggregates: note → start → 14 daily check-ins/progress → automatic completion → result |
| History persists across launches | **Done + tested.** The SwiftData store is reopened from disk in a test |
| History exportable as JSON | **Done + tested** (`hpl.insights_export.v1`) |
| Dismissed rec kinds de-prioritized in following days | **Done + tested** (per topic, 7 days) |
| One daily notification | **Not built** (see below) |

## Needs a device

- Real-life use over 14 days: check-ins, automatic completion on the first foreground after the end, and how the result reads with real Watch data.
- Making sure the SwiftUI flows (cards, the evidence navigation, file exporter, check-in buttons) feel right. CI only compiles the views and runs the model and logic tests.

## Not built yet

- **One daily notification** (architecture §5.4 step 6): a morning local notification that names the top note's topic. This needs `UNUserNotificationCenter` permission UX.
- A `BGProcessingTask` daily run. Today, notes and experiment completion run on foreground.
- Editing an experiment's start day; starting experiments that aren't tied to a note; running more than one at a time.
- Charts of the metric across baseline vs intervention.
- Delete-all for insights is in the repository (`deleteAll`) but isn't in Settings yet. It lands with M7 export/delete-all.
