# Milestone 3 verification report

Checkpoint date: 2026-11-13, Europe/Rome.

## Implemented

Version 0.3.0 adds versioned local arXiv PDF downloads, durable cancellable download/extraction jobs, immutable validated files, a native PDFKit reader, saved page position, text search, page extraction and stable page-linked chunks. Italian controls expose download/progress/retry, integrated reading, Preview, Finder, extraction and confirmed local removal. Schema V4 preserves the existing library and adds PDF records, jobs, pages and chunks.

Metadata import remains separate from PDF download. Extraction begins only after the file and download record are saved; extraction failure does not remove the PDF. This milestone adds no AI, OCR or semantic indexing.

## Executed verification

- Configuration, source-reference, localization and syntax checks passed.
- All **25 independent storage safety checks** passed.
- Swift Package Manager and Xcode each passed **57 tests in 8 suites**, including all 40 prior tests.
- Native Xcode Debug and Release builds succeeded using Xcode 27.2 on macOS 27.0.1 / arm64, targeting macOS 26.
- The actual PDFReaderSession opened/autoscaled a real fixture, restored page 2, persisted navigation to page 1, found a scientific term asynchronously, selected a result and released its document on close. LocalPDFView action-policy tests rejected external actions and allowed local page navigation.
- The opt-in live check used the application's metadata provider, scheduler, PDF transport, repository, PDFKit extraction and chunker against `1706.03762v1`. It downloaded **2,128,686 bytes**, verified SHA-256, extracted **15 source pages** into **21 page-linked chunks**, reported completed extraction and saved reading position 2.
- Release packaging produced `build/release/Paper Library.app`, version **0.3.0**, build **3**. Local ad hoc signing and strict signature verification passed.

Commands:

```sh
python3 Scripts/generate_xcode_project.py
bash Scripts/verify.sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run --scratch-path .build --cache-path .build/cache PDFLiveCheck --live
bash Scripts/build-app.sh release
codesign --verify --deep --strict 'build/release/Paper Library.app'
```

The ordinary test gate uses temporary stores and mocked network responses. The live check used a disposable temporary library and one public PDF; it did not open production data or contact an AI service. Core Data diagnostics from the deliberately corrupt-store fixture are expected and its preservation test passes. Xcode's AppIntents metadata warning is expected because the app has no AppIntents dependency.

## Coverage and design boundaries

Transport tests exercise actual URLSession streaming through URLProtocol fixtures, byte progress, advertised and streamed size limits, rejected hosts/redirects, HTTP failures and Retry-After. Filesystem fixtures cover disk reserve overflow, unsafe paths/symlinks, checksum corruption and preservation of changed destination bytes. PDF transfers use the same serialized request lease and persisted cooldown as metadata requests.

Coordinator/repository tests cover duplicate active requests, cached download reuse without a request, protected modified files before networking, cancellation and partial cleanup, explicit retry, separate source versions, invalid downloads preserving prior files, extraction failure retaining a readable document, confirmed local removal retaining notes, paper deletion cleaning files, interrupted-job recovery, reading-state/chunk persistence and V3 → V4 migration preserving import history and manual content.

PDFKit fixtures cover multi-page text, scans/empty pages, processing limits, exact source-page chunk bounds, stable IDs/hashes on re-extraction, technical text and conservative repeated-edge removal. Native reader tests caught and fixed PDFKit delegate recursion during autoscaling: the action guard is now a separate retained NSObject rather than the PDFView itself.

Files are staged, validated and atomically published before the database commit. There is no cross-filesystem/database transaction: a crash between publication and commit can leave an unreferenced valid file, which is preserved. Removal commits tombstones before physical deletion and retries cleanup locally. Owned stale partials are cleaned; complete unknown files are not automatically purged. Downloads restart on retry rather than resuming byte ranges.

Default limits are 100 MiB per transfer, a 64 MiB disk reserve, 2,000 extracted pages, 8 million total extracted characters and 200,000 characters per page. Settings exposes a 10–500 MiB transfer limit. PDFKit's internal parsing allocations are not a hard memory sandbox. Scans, blank/truncated pages and processing limits are reported as incomplete; mathematics and complex layouts may not extract faithfully. `chunksReady` indicates stored chunks, without embeddings.

The implementation retrieves individually requested papers, following [arXiv automated access guidance](https://info.arxiv.org/help/robots.html), and does not offer bulk crawling. [API terms](https://info.arxiv.org/help/api/tou.html) inform the shared conservative request pacing. Requests are pinned to HTTPS arXiv URLs and reject redirects.

## Remaining verification limits

The reader engine was executed through actual PDFKit in tests; the complete SwiftUI window/button workflow, Preview/Finder actions and native quit/cancel interaction were not manually reviewed. The external SkyComputerUseService failure recorded in [milestone 1](MILESTONE_1.md) remains unresolved. See the [milestone 3 native checklist](../MILESTONES.md) for the outstanding interaction review. Compilation and integration tests do not imply that review passed.

No 5,000-paper benchmark, full recovery drill, portable PDF backup, AI output, Ask Paper or entire-project completion is claimed. Preflight snapshots include PDF database rows and extracted text, not PDF file bytes. Milestone 4 remains pending.

Checkpoint logs are `/tmp/paperlibrary-m3-verification.log`, `/tmp/paperlibrary-m3-live.log` and `/tmp/paperlibrary-m3-packaging.log`. Xcode result bundles are under `build/DerivedData/Logs/Test/`.
