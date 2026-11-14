# Milestone 4 verification report

Checkpoint date: 2026-11-14, Europe/Rome.

## Implemented

Version 0.4.0 (build 5), schema V5, adds exclusively on-device Apple Foundation Models analysis. The app uses an explicit SystemLanguageModel with guided generation, real availability/locale checks, bounded context management and no inference tools or remote fallback. Three editable initial profiles and custom profiles support Italian/English abstract analysis and staged synthesis of extracted PDF text.

Structured results retain source kind, PDF record/version when applicable, source fingerprint, prompt version, exact profile snapshot, language, model API identifier, OS version and generated date. Factual points select source-passage IDs; the app supplies copied source evidence and PDF pages. Saved personal corrections and original AI evidence coexist. Regeneration creates a new history record and requires confirmation after a matching edited result. Per-paper topic editing protects manual choices from subsequent generation.

Durable AI jobs support serial processing, duplicate prevention, cancellation, failed/interrupted retry and normal-quit recovery. No AI begins automatically after import, extraction or launch. The existing app icon, fixed bundle identifier, storage roots and prior functionality are retained. This milestone does not add Ask Paper, semantic embeddings, OCR or portable backups.

## Executed verification

- Configuration/source-reference/localization/syntax validation passed.
- All **25 independent storage checks** passed.
- Swift Package Manager and Xcode each passed **76 tests in 10 suites**, retaining the 57 prior tests and adding 19 AI tests. Parameterized unavailable-model coverage also exercises five availability states.
- Xcode Debug and Release builds succeeded with Xcode 27.2, targeting macOS 26 on arm64.
- A minimal compiled Foundation Models probe ran before integration. This Mac reported model availability, Italian/English support and an **8,192-token context**, then generated a local Italian summary of synthetic text. The app reads the runtime context size.
- The opt-in AILiveCheck completed with the real Apple model, synthetic academic text, a generated two-page PDF and a temporary SwiftData library. It saved Italian and English abstract analyses, performed PDFKit extraction followed by separate excerpt analyses and a final technical synthesis, validated exact source/page provenance, enforced regeneration confirmation and retained a private fixture note.
- The live executable ran under a `sandbox-exec` policy denying its network operations. No production library, arXiv provider or remote inference service was used. This restricts the check process, not every system service or the entire Mac; no whole-Mac radio-off test is claimed.
- Release packaging produced `build/release/Paper Library.app` version **0.4.0**, build **5**. The existing icon is included; local ad hoc signing and strict signature verification passed.

Commands:

```sh
python3 Scripts/generate_xcode_project.py
bash Scripts/verify.sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product AILiveCheck --scratch-path .build --cache-path .build/cache
sandbox-exec -p '(version 1) (allow default) (deny network*)' .build/debug/AILiveCheck --live
bash Scripts/build-app.sh release
codesign --verify --deep --strict 'build/release/Paper Library.app'
```

The ordinary gate injects a model fixture and does not invoke live inference. Core Data diagnostics from the deliberately corrupt-store fixture are expected. Xcode's AppIntents warning is expected because this app has no AppIntents dependency.

## Important regression coverage

Tests cover durable successful results, duplicate active requests, separation from notes/metadata/favorites, source/profile/language attribution, case-normalized topics and failed regeneration preserving earlier output. Actual unavailable-state messages are mapped to SDK reasons; fixture tests prove failed jobs can be retried without losing the paper.

Edited-result tests require confirmation, preserve both versions, reject a result when a correction is saved during generation and retain edits after closing/reopening. Source-change tests reject stale results. Cancellation prevents a late commit and allows another queued paper to continue. Normal termination saves interruption before cancelling the model task; startup leaves interrupted work idle until explicit retry.

PDF tests verify separate excerpt/reducer calls, source version and exact source-page provenance, incomplete-extraction attribution, the 64-chunk coverage limit and preservation of analysis history after local PDF removal. The V4 → V5 migration test retains PDF text, reading position, completed PDF jobs and notes, creates the pre-open snapshot and permits the new profile/job models. Prior V1/V2/V3 migration tests now run through the V5 plan.

Validation tests reject unsupported numeric literals, fabricated quotes, unknown source IDs, empty results and confidently detected wrong-language output. Context fixtures force recursive splitting and aggregation. Prompt tests verify that external text remains encoded in the prompt rather than trusted instructions. These are structural and source-integrity checks, not a general semantic proof against prompt injection or hallucination.

Topic/profile tests preserve historical profile instructions, enforce size limits, retain manual topic choices during regeneration, reuse existing normalized topic IDs and roll back an invalid multi-topic edit atomically. Paper deletion removes analysis/topic references, cancels dependent work and retains courses.

## Changes driven by the real-model check

Early live runs exposed output that fixtures could not: an Italian request answered in English, an omitted summary and source quotes contaminated with JSON/schema framing. The final schema requires a summary, states output language in instructions and prompt, and asks the model to select numbered source passages. The app resolves those IDs and copies source text itself. A local language heuristic rejects a confident opposite Italian/English result. The complete synthetic abstract/PDF workflow then passed with the real model.

Each excerpt gets a fresh session. On macOS 26.4+, token counting includes instructions, prompt and the actual guided schema, reserving 1,400 response tokens plus 384 tokens for framing/headroom. On 26.0–26.3 an estimate is used; those older systems were not runtime-tested here. Context overflow triggers bounded splitting rather than sending an entire long document to one session.

Abstracts are capped at 192,000 characters; PDF analysis fetches at most 65 chunks and processes the first 64, labeling incomplete extraction/coverage. Excerpt processing has a 160-call budget and six split levels. The reducer selects up to twelve representative intermediate facts and shrinks the selection if its prompt exceeds context. Interrupted work restarts; intermediate model outputs are not checkpointed.

## Verification limits and remaining milestones

The complete SwiftUI button/window workflow, profile editor, native cancellation/quit dialogs and reader interaction with the analysis panel have not been manually reviewed. The external SkyComputerUseService failure recorded in [milestone 1](MILESTONE_1.md) remains open; see the [milestone 4 interaction checklist](../MILESTONES.md). Command-line and native PDFKit tests do not imply that this review passed.

The real-model fixtures verify usable Italian/English output and staged technical synthesis on this Mac. They are not a broad scientific-quality benchmark. Exact references and numeric checks do not prove that a paraphrase is entailed by its evidence; model interpretations and scientific conclusions still require human review. The language check is heuristic. Model availability and output quality can vary with system/model updates.

No 5,000-paper performance claim, full recovery drill, complete semantic injection defense, global topic merge UI, Ask Paper or whole-project completion is made. Preflight database snapshots preserve analyses and source text but do not copy PDF file bytes. Portable export/backup is milestone 5 and remains pending.

Apple's [SystemLanguageModel documentation](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), [context management](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window) and [generative output safety guidance](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output), together with the installed SDK interfaces, informed the implementation.

Logs: `/tmp/paperlibrary-m4-probe.log`, `/tmp/paperlibrary-m4-tests.log`, `/tmp/paperlibrary-m4-verification.log`, `/tmp/paperlibrary-m4-live.log`, `/tmp/paperlibrary-m4-packaging.log`. Xcode result bundles are under `build/DerivedData/Logs/Test/`. The live log contains synthetic fixture output only; production analysis code does not print source text or notes.
