# PDF sections and source-validation follow-up

Verified on November 14, 2026. This follow-up supersedes the abstract-only source policy recorded in RESEARCH_REVIEW.md.

## Behavior

New summaries use the newest downloaded PDF with extracted text, falling back to the abstract when no usable PDF text is available. There is no source or version selector. The section parser excludes bibliography, acknowledgments and appendices. A bounded passage selection covers introduction, method, experiments/results and conclusions, favoring method/results/conclusions instead of taking only the start of a long document.

The model's exact token check includes source, instructions, schema, corrective prompts, reserved output and safety headroom. If the selected PDF passages exceed context, the selection shrinks while retaining document-wide section coverage. Quotes remain verbatim passages from the selected source, with their original page numbers. Results explicitly describe selected-section coverage; a long PDF is not presented as fully analyzed.

The duplicate Style label beside the slider is hidden while retaining its accessibility label. The “Your choice is saved…” sentence has been removed. The style preference still uses the same persistent key.

## Source validation

The reported failure was reproduced for the public abstract of “Differentiable Blocks World: Qualitative 3D Decomposition by Rendering Primitives,” using Research Review in English. A subsequent native check exposed a PDF case where inline evidence labels such as `[0]` and `[17]` were mistaken for quantitative claims. Recognized inline evidence references are now removed from prose because source links are already rendered by the app. Unknown references and actual numerical claims remain subject to validation; array indexing such as `x[0]` is preserved.

Required summary validation remains strict. Unsupported optional details are omitted without discarding a verified summary. If two attempts cannot produce valid output, a final fresh session requests a shorter summary using a smaller schema. Every accepted result still passes source-reference, number and language checks; unsupported claims are not saved as a fallback. Diagnostic callbacks are opt-in for the public-fixture verification executable and disabled in the application.

## Automated and model checks

- `Scripts/verify.sh`: 84 tests in 11 suites passed through Swift Package and Xcode; Debug and Release builds succeeded.
- Regression coverage verifies that inline evidence labels are normalized without accepting unsupported quantitative claims, invalid optional details are omitted, invalid required summaries are rejected, bibliography/appendices are excluded, conclusions retain page provenance, passage selection adapts to context, and retries use the current style and available PDF.
- The public Blocks World abstract passed all three styles in both English and Italian with the real Apple model. Research Review produced 8 and 7 verified source references respectively.
- The real 19-page geometric primitive decomposition PDF supplied 39 body parts and 80,983 characters after removing excluded sections. The installed model's context was 8,192 tokens. Adaptive selection produced successful Research Review summaries in English and Italian, using 32 body parts and 16 and 14 verified references respectively. Both results accurately recorded partial coverage.
- The 17-page version-2 Blocks World PDF was downloaded through the app. Its selected sections passed the real-model Research Review check in English and Italian after correcting inline evidence references, using 15 body parts with 4 and 10 verified references respectively.
- The final Release app was packaged at the canonical path; the single-app check and strict code-signature verification passed.
- Native end-to-end retry on Blocks World saved an English `PDF v2` summary, retained the older analysis in Previous Versions, and removed the error/Retry state. Dangling phrases left after inline reference removal are cleaned for generated summaries, including previously saved results; personally edited text is left intact.

The verification fixtures contain public paper text only. Production code does not log source material or user notes. Existing saved analyses, edits and downloaded files are preserved.
