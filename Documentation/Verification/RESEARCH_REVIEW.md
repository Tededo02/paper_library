# Research Review and summary controls

Verified on November 14, 2026.

## Result

The summary three-dot button opens a popover containing a discrete style slider directly. Moving the slider writes `ai.defaultProfile`, the same preference used in Settings. The selected style applies to other papers and the PDF reader's summary panel, and survives quitting and reopening the app.

New summaries use only the abstract. The Source Text and PDF Version controls have been removed. Retry uses the current style and analysis language, and starts an abstract summary instead of replaying an old failed PDF request. Saved analyses, edits, notes, PDFs and historical source/version information are retained.

## Context measurement

The installed `SystemLanguageModel.default` reported a context size of **8,192 tokens**. PDFKit extracted **88,503 characters over 19 pages** from the PDF involved in the reported failure. The model's own `tokenCount(for:)` returned **26,372 tokens** for that text alone.

This exceeds the available context before adding instructions, schema or output, so the interface uses the requested abstract-only fallback. The internal staged PDF pipeline remains available for historical jobs and integration checks; it is not selected by the summary controls.

Apple documents that instructions, input, schemas and generated output all consume context in [Managing the on-device foundation model's context window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window).

## Language correction

Research Review failures in the existing library recorded Italian PDF requests rejected for returning the wrong output language. Generation now makes one corrective attempt in a fresh session for language, citation or structured-output validation failures. The retry prompt reinforces the requested language, and its tokens are included in the preflight budget. The older-system estimate uses UTF-8 byte counts conservatively.

Language validation checks the factual sections and Research Review interpretation individually, as well as their combined text. Source quotations and scientific topic labels retain their original language. Invalid results continue to be rejected without replacing earlier analyses.

## Verification

- `bash Scripts/verify.sh`: passed; 80 tests in 11 suites through both Swift Package and Xcode, plus Debug and Release builds.
- Regression coverage: a new summary after a failed PDF review uses the current style and abstract; edited-summary confirmation remains enforced; mixed-language Research Review interpretations are rejected.
- `AILiveCheck --review-regression`: the same public abstract, “Superquadric Primitive Decomposition of 3D point clouds via Geometric-Aware Inlier Refinement,” passed with the real Apple model in English and Italian, with 9 and 8 verified source references respectively.
- Native accessibility check: the three-dot button opened the slider directly, without source/version selectors. Research Review remained selected on a different paper and after a complete app restart.
- Native end-to-end retry: the affected paper generated and saved an English abstract summary with `Research Review · EN`. The previous error and Retry button disappeared, and the older analysis remained in Previous Versions.
- `bash Scripts/build-app.sh release`: passed, replacing the canonical app only.
- `python3 Scripts/check_single_app.py`: exactly one persistent app at `build/release/Paper Library.app`.
- `codesign --verify --deep --strict`: passed for the final app.

Functional native checks used accessibility state. The computer-use screenshot service returned a scaled window thumbnail, so this follow-up does not claim a full-resolution visual layout review.
