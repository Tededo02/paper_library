# Implementation milestones

The full scope is delivered incrementally. The user explicitly requested milestones 2, 3 and 4 after the preceding automated gates passed. Milestone 4 now has implementation, automated verification and real on-device abstract/PDF analyses with network access denied to the integration-check process. Native interface verification remains recorded separately; milestone 5 has not been started.

| Milestone | Deliverable | Verification gate | Status |
| --- | --- | --- | --- |
| 1 | Manual offline library; courses; notes/status/favorites; explicit schemas; storage isolation; recovery diagnostics | Storage checks, SwiftData reopen/migration/integrity tests, Xcode Debug/Release builds and native UI smoke test | Automated gate and release signing passed; entry/assignment/relaunch smoke passed; inspector interaction checks pending |
| 2 | Safe arXiv parser/provider; bounded/allowlisted networking; persistent cancellable batch imports; deduplication | Parser and Atom fixtures; mocked redirects/timeouts/retry/rate limits; metadata saved before subsequent processing; restart/retry checks; official endpoint verification | Implemented; automated gate and live HTTPS check passed; native import interaction review pending |
| 3 | Versioned local PDF storage, download cancellation/checksums, PDFKit reader, page extraction/chunking | PDF fixtures and invalid downloads; atomic publication without overwriting; cancellation/restart consistency; actual reader session and page mapping; live PDF retrieval | Implemented; 57 tests, 25 storage checks, Debug/Release and live PDF check passed; native interface review pending |
| 4 | Exclusively on-device Foundation Models; profiles; abstract/full-paper analyses; topic editing | Minimal compiled SDK integration; actual availability states; structured source references; edited-output protection; context/cancellation tests; compatible-device generation with denied process networking | Implemented; 76 tests, 25 storage checks, Debug/Release and real-model integration passed; native interface review pending |
| 5 | Portable versioned JSON export/import, validated restoration, backups/recovery, BibTeX | Full round trip of user content and stable IDs; invalid path/schema input rejected before writes; recovery drill; reliable BibTeX escaping | Pending |
| 6 | Topic management; course-specific context UI; remaining filters/smart views; lexical + local semantic indexing | Local embedding capability/language checks; cache invalidation; lexical fallback; measured search/indexing performance and responsiveness | Pending |
| 7 | Manual/suggested relations; grounded Ask Paper; clickable PDF page references; complete reader workflow | Verified source-page citations; prompt-injection fixtures; insufficient-evidence and context-growth checks; offline retrieval/Q&A tests | Pending |
| 8 | Lifecycle hardening, full diagnostics, accessibility, large-library validation and acceptance audit | Interrupted job recovery; all migrations; Debug/Release replacement drill; measured benchmarks; acceptance criteria checked individually | Pending |

## Milestone 1 review steps

`bash Scripts/verify.sh` now passes with Xcode 27.2, and `bash Scripts/build-app.sh release` produces a verified locally signed app. Native interaction verification created two clearly named demo courses and one paper, assigned it to both courses, and confirmed author order and memberships after a process restart. Those demo fixtures remain available for review. No production library was opened.

Selecting a paper causes the external `SkyComputerUseService` automation process to terminate with an assertion in `Array.remove(at:)`; the app remains running. Resetting the automation session, using keyboard navigation and disabling snapshot diffing did not resolve this limitation. The inspector, failed-write/termination and remaining contextual-action review steps below have not been completed through the native UI. Repository tests cover notes, metadata edits, reading state, favorites, assignments and deletion independently.

1. Launch the shared Xcode scheme with its explicit `--demo` argument. Confirm Settings reports the `.demo` storage root.
2. Create two courses. Rename one, edit description/color and reorder them.
3. Add a paper manually with ⌘⇧N, multiple authors and an abstract. Assign it to both courses.
4. Edit notes, favorite and reading state. Change metadata and confirm the note is retained.
5. Quit normally and relaunch. Confirm content, identifiers and membership counts persist.
6. Remove the paper from one course; delete the other course after confirmation. Confirm the paper and notes remain under All Papers.
7. Add another paper; test multiple selection, bulk assignment, search, filters and confirmed paper deletion. Cancel one deletion and confirm nothing changes.
8. Open Settings and inspect database/schema/snapshot paths. Launch a second process against the same demo root; it must show recovery diagnostics rather than open another store connection.
9. Run the Release build with `--demo` and confirm the same demo library appears. Do not use production data for this verification.
10. Exercise a failed note write in a disposable demo environment: the draft must remain visible and normal quit must retry or cancel termination. Never damage the production database to test an error path.

## Milestone 2 review and handoff

See [the verification report](Verification/MILESTONE_2.md) for executed checks and their limits. The implementation retains the existing library path and upgrades V2 stores to schema V3 with a pre-open snapshot. The default build/test gate remains offline; the live check is an explicit separate command.

1. Launch the new app through the shared demo scheme. Press ⌘N and confirm that the import dialog shows the destination, duplicate/invalid counts, options and durable history.
2. Import `1706.03762v1` into a demo course. Confirm the original title/authors/abstract and source version, with no AI output or PDF download implied.
3. Repeat that ID into another course. Confirm one global paper and retained notes; exercise assignment opt-out and explicit refresh.
4. Import a longer batch, close/reopen the dialog and inspect progress. Cancel a running batch; completed imports must remain. Retry a failed/interrupted job using the selected destination/options.
5. Quit during a metadata request and relaunch. Confirm unfinished jobs are interrupted and no network request starts until retry is chosen.
6. Test an unsupported host and a malformed ID; neither may trigger automatic fetching. Use manual entry as the fallback.

These native steps are not reported as completed by the command-line integration tests. The prior automation-service failure and inspector review remain open; there is no claim that the complete application specification has been delivered.

## Milestone 3 review and handoff

See [the verification report](Verification/MILESTONE_3.md) for executed checks and limits. Version 0.3.0 upgrades to schema V4 while preserving the storage root and existing content. Unit tests exercise actual PDFKit opening/autoscaling, local actions, saved page position and asynchronous search; these do not substitute for the following interface review.

1. Launch with `--demo`, import an arXiv paper and choose **Scarica PDF**. Confirm progress and separate download/extraction states; a successful download remains readable even if extraction fails.
2. Open the PDF, navigate pages, zoom, use search and contents when available, and edit notes beside the document. Close and reopen; confirm reading position and notes persist.
3. Open Preview and reveal the file in Finder through the actions menu. Remove a local PDF, first cancelling the confirmation, then confirming it; metadata and notes must remain.
4. During a sufficiently long transfer, cancel and retry. Quit during processing and reopen; unfinished jobs must require explicit retry without an automatic network request.
5. Refresh metadata to another explicit version and download it. Confirm both local versions remain available. Repeating a download for a valid local file must reuse it.
6. In disposable demo data only, preserve a copy before modifying a downloaded file externally. Confirm opening/re-downloading reports the checksum mismatch and leaves the changed file available through Finder. Remove it with confirmation before downloading again.
7. Set a lower PDF size limit in Settings; a larger transfer must fail with an actionable message and no valid partial document. Check registered PDF count and size in diagnostics.

The milestone 3 native interface checklist is pending because the external automation service still fails during table selection, as documented above. AI was subsequently added through the explicitly requested milestone 4 below. OCR, semantic embeddings, portable backup and Ask Paper remain outside these checkpoints.

## Milestone 4 review and handoff

See [the verification report](Verification/MILESTONE_4.md). Version 0.4.0 uses schema V5, retaining the fixed storage root, V1–V4 migration path and existing app icon. Real-model checks used synthetic source material in a temporary library. The process network restriction is not a whole-Mac radio-off test. The following native interaction review remains pending:

1. Launch the demo scheme and open Settings. Check the actual Apple-model availability, Italian/English setting and default profile. Edit a profile objective and add a custom profile; relaunch to check persistence.
2. Select a paper with an abstract, choose **Solo abstract** and **Analizza sul Mac**. Inspect the summary, source passages, explicitly unspecified fields and saved source/profile/language attribution. Confirm original metadata and personal notes remain unchanged.
3. Choose Italian and another profile, then repeat. For **Research Review**, verify that hypothetical questions appear separately from author claims.
4. Download/extract a PDF, choose the appropriate version and run a technical analysis. Review its source pages. A scan, partial extraction or document beyond 64 extracted chunks must show incomplete coverage rather than claim a complete-paper analysis.
5. Modify a saved analysis and save it. Regenerate, cancel the confirmation once, then confirm. Check both versions remain and the personal text is unchanged. Edit topics; later generation must preserve those choices.
6. Cancel a running analysis, then retry. Quit during generation and relaunch; incomplete work must be interrupted until explicit retry. Change source metadata during generation and confirm a stale result is rejected.
7. When the model is unavailable, check that diagnostics explain the actual SDK reason and that imports, notes, courses, search and PDF reading still work. Do not alter production data to simulate failures.

No global topic merge interface, semantic retrieval, Ask Paper, portable backup or whole-project completion is implied. Milestone 5 remains pending until separately requested.

## Requirement assumptions

The first supplied attachment ends midway through section 19; sections 20–27 were absent. The user explicitly authorized inferring the missing requirements. These assumptions are project decisions, not recovered original text:

- Portable backups should have stable IDs, complete user content, explicit format versions and conflict-aware merge/restore choices, with validation before any active-store mutation.
- Import/export and PDF inclusion should use native file dialogs and safe relative references; archive support is optional and must validate extraction limits.
- Settings should cover generation language, default analysis profile, storage diagnostics, PDF limits and index maintenance.
- Accessibility, actionable errors, cancellation/retry, privacy documentation, fixtures and acceptance checks apply to every vertical slice.
- Distribution is local through Xcode/ad hoc builds, with a documented app replacement process and unchanged production storage.
- No inferred requirement authorizes cloud inference, destructive recovery, arbitrary automatic URL fetching or removal of user-authored content.

The supplied [original partial specification](Requirements/ORIGINAL_PARTIAL.md) and [supplement, sections 28–41](Requirements/SUPPLEMENT.md) are preserved verbatim and remain the authoritative scope where they provide concrete requirements. All later features are pending, not silently dropped.


### 0.4.2 maintenance checkpoint

The interface was simplified and multi-passage summary validation corrected after the user reported all three profiles failing on a paper. This does not advance the milestone number. See [interface and AI verification](Verification/INTERFACE_AND_AI.md). Current summary controls use the Sintesi tab and Crea sintesi; older acceptance steps above retain their historical wording.
