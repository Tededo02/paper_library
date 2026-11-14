# Milestone 2 verification report

Checkpoint date: 2026-11-13, Europe/Rome.

## Implemented

Milestone 2 adds validated arXiv ID/URL parsing, namespace-aware Atom metadata retrieval, bounded HTTPS transport, globally serialized/persisted request pacing, a durable batch-import coordinator, deduplication, optional protected metadata refresh, cancellation/retry/restart recovery and an Italian native import/history dialog. The app version is 0.2.0; the database schema is V3. PDF downloading and AI are not part of this milestone.

The existing Milestone 1 interactive inspector limitation remains open. The user explicitly requested advancing to Milestone 2 while retaining that status.

## Executed verification

- Configuration/source-reference/localization checks and Swift syntax validation passed.
- The 25 independent storage safety checks passed.
- The Swift Package Manager and Xcode test runners each passed **40 tests in 5 suites**, including the original persistence tests, V2 → V3 migration, identifier/Atom fixtures, real URLSession protocol stubs, request pacing, retries and import lifecycle checks.
- Native Xcode Debug and Release builds succeeded on macOS 27.0.1 / arm64 with Xcode 27.2, targeting macOS 26.
- The opt-in live HTTPS integration check succeeded against `https://export.arxiv.org/api/query`: `1706.03762v1` was imported into a temporary SwiftData library with its title, eight authors, abstract, explicit version and course assignment. A duplicate version-2 input reused the global record and retained the local note and original version.
- The release packaging script produced `build/release/Paper Library.app`; local signing and strict signature verification were executed. The artifact reports version 0.2.0.

Commands:

```sh
bash Scripts/verify.sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run --scratch-path .build --cache-path .build/cache ArxivLiveCheck --live
bash Scripts/build-app.sh release
codesign --verify --deep --strict 'build/release/Paper Library.app'
```

Ordinary automated tests use mocked network responses and temporary stores. The live check is opt-in and retrieves public metadata only. No production library, PDF or inference service was used. Core Data errors from the intentional corrupt-store fixture are expected; the preservation test passes.

## Important coverage

Identifier fixtures cover modern/legacy formats, versions, PDF suffixes, canonical normalization and exact-version input deduplication. Unsafe schemes, hosts, user information, ports, encoded traversal and query strings are rejected. Atom fixtures check namespace handling, source fields, author order, Unicode/CDATA, dates, DOI, journal reference, malformed/incomplete XML, external declarations and untrusted PDF links.

Transport tests exercise actual URLSession/AsyncBytes with URLProtocol fixtures, including host rejection before a request, redirects, advertised oversize and streamed oversize. Scheduler/client tests cover batching, bounded HTTP/transient failures, immediate offline failure, numeric/date Retry-After, long persisted cooldowns, concurrent callers and independent schedulers sharing an OS lease/deadline. The shared-deadline timing test uses a real monotonic clock to match the persisted wall-clock deadline; it also verifies one in-flight request.

Repository/coordinator tests cover durable metadata/job completion, duplicate import without another fetch, course assignment opt-out, preservation of manual metadata and annotations during refresh, failed refresh without data loss, malformed inputs, missing results/wrong versions, retry, twenty-ID batches, cancellation after earlier chunks were saved, continuation of another batch, normal termination interruption and recovery of interrupted work after reopening. The V2 migration test preserves notes, ratings, associations, course context and color, verifies backup creation and writes new job rows.

## Design and service verification

The official [arXiv API terms](https://info.arxiv.org/help/api/tou.html) were consulted for the three-second/single-connection limit. The [official API manual](https://info.arxiv.org/help/api/user-manual.html) documents `id_list`, Atom fields and explicit version queries. The HTTPS endpoint returned an actual HTTP 200 Atom response in this environment, first through a direct check and then through the application's own URLSession/provider/import path.

Rate control is shared between production/demo configurations in `local.paperlibrary.app.network`, separate from user libraries. The request lease spans a network request; both failures and successes extend the minimum next deadline. Retry-After is persisted before releasing the lease. Long delays surface a retry-later error without bypassing the server's requested interval. Tests never use that production/demo shared policy directory.

## Remaining verification limits

The import UI is implemented and compiled, but its native interaction checklist has not been completed in this session. The known external SkyComputerUseService crash documented in [Milestone 1](MILESTONE_1.md) remains unresolved; no new native UI success is inferred from compilation or command-line tests. Dialog closure/reopening, native button/keyboard flows, error layout and quitting through the UI should be reviewed using [the Milestone 2 checklist](../MILESTONES.md).

No 5,000-paper performance result, full recovery drill, PDF workflow, AI output, semantic search or entire-project completion is claimed. The next development slice is Milestone 3, only when requested.

Build/test/live/package logs for this checkpoint are `/tmp/paperlibrary-m2-verification.log`, `/tmp/paperlibrary-m2-live.log` and `/tmp/paperlibrary-m2-packaging.log`. Xcode result bundles are under `build/DerivedData/Logs/Test/`.
