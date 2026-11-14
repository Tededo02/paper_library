# Local PDF import

Verified on November 14, 2026.

## Behavior

Add Papers (⌘N) presents a native segmented choice between arXiv Link and PDF File. The PDF panel offers the system file chooser and a file drop target, followed by editable title/authors and the existing course picker. Embedded PDF metadata supplies initial values when available; the filename supplies a fallback title. The original file is read without modification and copied into managed library storage.

Local imports create a paper, PDF record, course membership, completed import-history item and pending extraction job in one database transaction after validating and publishing the file. They use the existing immutable PDF layout, size limit, disk reserve, checksum validation, reader and extraction pipeline. Security-scoped file access is held while inspecting/copying the selected file. Cancellation discards owned staging files and uncommitted copies.

Matching checksums reuse a paper while preserving its metadata, notes and existing course assignments. Removing and reimporting a local PDF restores its record; deleting a paper and importing the same file again creates a fresh paper identity. Local papers do not pretend to have an arXiv identifier or show arXiv download/version actions.

Extracted text enables the existing PDF-section summaries without requiring an abstract. Scanned PDFs remain readable and are marked as having no extractable text; the summary panel explains that an abstract can be added manually. No network request or paper-summary generation starts during local import. A subsequent update adds automatic on-device recovery of missing authors/abstract while reviewing the file; see PDF_METADATA.md.

## Checks

- Scripts/verify.sh passed with 90 tests in 11 suites through both Swift Package and Xcode, plus Debug and Release builds.
- Scripts/build-app.sh packaged the final Release app at the canonical path. The single-app check and strict final code-signature verification passed.
- The native chooser was exercised through Add Papers → PDF File → Choose PDF, metadata review, title editing and Add. Reimporting an existing public PDF closed the sheet, selected the existing paper and retained the three-paper library without duplication or metadata changes.
- Automated coverage verifies metadata reading, copy integrity, preservation of the original, course assignments, offline extraction and summary source selection, duplicate handling, invalid/oversized/cancelled imports, restoration, reopening the library, scanned documents and fresh identity after paper deletion.
- Functional native checks used accessibility state. The screenshot service returned a scaled window image; no full-resolution visual layout review is claimed.

The storage schema, bundle identifier and canonical application path are unchanged. Native verification uses the isolated products managed by Scripts/verify.sh.
