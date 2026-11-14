# Automatic PDF metadata recovery

Verified on November 14, 2026.

The local PDF import preview requests the printed article title from Apple's on-device Foundation Model, plus authors and abstract when those fields are missing. The filename is the title fallback only if the model is unavailable, no text is readable, or the proposed title cannot be verified. Existing author/abstract metadata is retained. The model receives at most the first three pages, bounded to 20,000 characters and stopped at the Introduction heading when present. Actual token counts include instructions, schema, input, reserved output and headroom; oversized input is reduced before generation.

The title and authors must occur in the front matter/byline; an arXiv identifier is not accepted as a title. The abstract is a verbatim source excerpt, with whitespace and wrapped hyphens normalized. A near-exact model transcription can be located through matching opening/closing text and high word overlap, then replaced with the exact original source span. It retains the source language and is not a generated summary. Ungrounded values are omitted. No tool, external knowledge or remote model is supplied to the session.

The preview shows progress while recovering details and includes an editable Abstract disclosure. User edits made during recovery, including deliberately cleared fields, are preserved. A different file or cancelled sheet cancels the request and discards stale results. If recovery is unavailable or information is missing, manual editing and import remain available. Reimporting a duplicate fills empty persisted authors/abstract fields. A local paper title matching an original import filename can be replaced by a recovered title, while custom titles and filename fallbacks are protected.

## Verification

- Scripts/verify.sh passed: 100 tests in 11 suites through Swift Package and Xcode, plus Debug and Release builds.
- Tests cover requesting only missing author/abstract fields while always reading the title, source grounding, original abstract text, manual-edit protection, saving recovered values, duplicate imports and an unavailable model.
- The title update always requests the printed title, including when PDF metadata already has a title. Tests cover a verified title taking priority over filename/export metadata, failure fallback, manual-title protection, recovery of exact source abstracts from near-exact transcriptions, and correction of persisted filename placeholders on reimport.
- The real Apple model recovered the complete printed title of the public Blocks World PDF, all five authors in printed order and its original 1,433-character abstract. The test used a temporary library and left production data unchanged.
- The native import panel showed automatic progress, then populated the five authors and the editable Abstract field. A title edited during recovery remained unchanged. Cancelling the verification preview retained the original three-paper library without adding data.
- The updated native import panel automatically recovered “Vehicle sideslip estimation: A kinematic based approach” from a local PDF whose existing library title was its original filename. Reimporting the same content updated that title, retained the authors and abstract, and kept the ACAV course at one paper without duplication.
- The final Release app was packaged at the canonical path. The single-app check and strict code-signature verification passed.

The fixed application identifier, library schema and single persistent app path are unchanged. Production code does not log PDF content or extracted metadata.
