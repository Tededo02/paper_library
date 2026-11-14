# Interface simplification and summary reliability

Checkpoint: 2026-11-14, Europe/Rome. Version 0.4.2, build 7. SwiftData schema remains V5.

## Interface changes

- Library toolbar: one add menu, one filter menu, search and inspector toggle. Favorites has a sidebar destination. Counts use the navigation subtitle instead of a footer. The empty inspector is hidden until selection.
- Native table: titles and authors share a column; favorite/PDF indicators appear only when present. Reading status and added date remain sortable where applicable. Every column reserves 62 points; native rows measure 70 points throughout insertion and resize.
- Inspector: separate Details, Notes and Summary tabs. One main PDF action. Metadata, course membership, versions and maintenance actions are in menus. Notes retain immediate persistence and failed-write recovery.
- Summary: latest result appears directly, with optional details and all source passages. Previous versions are collapsed. Style/source settings are in a popover. Only the active task or latest retryable failure is shown; completed jobs no longer fill the panel.
- Import: compact entry form, optional settings, then a separate activity view. Full import history remains accessible from the add menu.
- Reader: the PDF takes the full reading area until the notes/summary panel is requested. Secondary view controls use a menu. Settings hides storage internals under Advanced and removes milestone/development prose from the normal interface.

## Reproduced summary failure

Public abstracts were retrieved from the primary arXiv API for [Iterative Superquadric Recomposition](https://arxiv.org/abs/2309.02102) and [Geometric-Aware Inlier Refinement](https://arxiv.org/abs/2609.35725). Neither production data nor personal notes were used.

With the previous model implementation, all three profiles failed source validation for the second abstract. A generated statement could combine facts from several passages while the schema permitted only one supporting passage. Numeric terms such as 3D then failed validation when absent from that single chosen passage. Source selection also occurred after generating the statement.

The guided schema now selects up to four source IDs before generating each statement. The app copies each referenced passage and validates it against the original text. Numeric literals must occur among those verified passages; fabricated quotes and unsupported numbers are still rejected. Aggregation retains all supporting passages and PDF page references. One bounded corrective attempt is allowed for a grounding failure, with a fresh local session and cancellation checks. Invalid results are never saved.

Supporting quotes are optional fields in saved JSON, with backward decoding of previous single-quote analyses. No database migration or production-data rewrite was needed.

## Executed checks

- `bash Scripts/verify.sh`: 25 storage checks, **79 tests in 11 suites** under SwiftPM and Xcode, Debug and Release builds. Temporary app products were cleaned up.
- New regression tests verify multi-passage numeric support, separate source pages for one point, preservation through aggregation/JSON, rejection of invented additional evidence and unsupported numbers, and decoding of historical single-quote JSON.
- The native table regression retains the same NSTableView, selection and resized title-column width through real coordinator imports, metadata changes, resize and deletion. Uniform measured row heights: 70 points.
- Real Apple model: both public abstracts passed in all three profiles, **6 of 6 analyses**, with verified source references. The check process had network access denied during inference.
- Existing live integration check passed again: Italian and English abstract analyses, PDFKit extraction of a synthetic two-page PDF, staged synthesis, verified original page references, edited-result confirmation and note preservation in a temporary repository.
- Release packaging replaced the canonical `build/release/Paper Library.app`. Info.plist reports 0.4.2/build 7, the icon matches the source asset, strict signature validation and the single-app check passed.

Native UI automation disconnected with `Sky Computer Use native pipe closed before response`, including after resetting the connection. Therefore no new full-screen visual comparison or live click-through is claimed. Compilation and the native table layout check passed; the full redesigned interface still needs visual review in the running app. The old app process was still open during packaging, so the user must quit and reopen to load the new executable. The Application Support library was not modified by verification.

Logs: `/tmp/paperlibrary-clean-verification.log`, `/tmp/paperlibrary-clean-ai-baseline.log`, `/tmp/paperlibrary-clean-ai-fixed.log`, `/tmp/paperlibrary-clean-ai-pdf.log`, `/tmp/paperlibrary-clean-packaging.log`.

The opt-in public abstract check accepts a local JSON array of objects with `title` and `abstract` fields:

```sh
sandbox-exec -p '(version 1) (allow default) (deny network*)' .build/debug/AILiveCheck --public-abstracts /tmp/paperlibrary-public-abstracts.json
```

The process-level network restriction does not disable all system services. Source matching and numeric checks do not prove semantic correctness; important scientific claims still require reading the paper.
