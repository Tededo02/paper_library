# Milestone 1 verification report

Checkpoint date: 2026-11-13, Europe/Rome.

## Result

**The automated build/test gate passes; the native interaction review remains partly open.** The application compiles in Debug and Release, eleven persistence/repository tests pass in both runners, and the locally signed release bundle passes signature verification. Native entry of two courses and a paper assigned to both was exercised, including persistence across a process restart. Inspector interaction checks were interrupted by a crash in the external UI automation service.

The entire application specification is not complete. No later milestone has been started.

## Environment actually inspected

- macOS 27.0.1, arm64; Apple Swift 6.4.2.
- Xcode 27.2, build 27B52, installed at `/Applications/Xcode.app` with initial setup complete.
- The system developer selection remains `/Library/Developer/CommandLineTools`.
- Build scripts use full Xcode through process-local `DEVELOPER_DIR` when needed, without changing that global selection.
- The original missing-`SwiftDataMacros` failure is resolved by using full Xcode.

## Executed checks

| Check | Actual result |
| --- | --- |
| `python3 Scripts/check_project.py` | Passed: source references, configurations, package products, scheme, localization and Swift syntax |
| `StorageChecks` with the Xcode toolchain | 25 checks passed |
| Swift Package Manager app compilation and `swift test` | Build succeeded; 11 tests in 2 suites passed |
| Xcode Debug build | `BUILD SUCCEEDED` |
| Xcode Debug test action | `TEST SUCCEEDED`; the same 11 tests passed |
| Xcode Release build | `BUILD SUCCEEDED` |
| `bash Scripts/build-app.sh release` | Succeeded after correcting bundle resource placement |
| `codesign --verify --deep --strict` on the final app | Passed |
| Native demo entry and process restart | Two courses, one paper, ordered authors and both assignments persisted |
| Inspector and remaining extended native review | Not completed: UI automation service crashes after row selection |

The successful automated gate was run as:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Scripts/verify.sh
```

The scripts also now select this installed Xcode automatically when Command Line Tools is the global default. Packaging was separately executed with the updated script:

```sh
bash Scripts/build-app.sh release
codesign --verify --deep --strict 'build/release/Paper Library.app'
```

The resulting app is `build/release/Paper Library.app`, an arm64 Mach-O executable in a locally signed bundle. Launching this app normally uses production storage; the interactive review used the Xcode scheme's explicit `--demo` argument.

## Persistence coverage

The eleven tests cover:

- Closing and reopening a real SwiftData store with notes, ordered authors, favorite, reading state and membership intact.
- Creating V1 data and upgrading through the production V2 migration plan, preserving identifiers, arXiv version, abstract, notes and course context; verifying pre-open backup creation.
- Preserving an invalid database and its backup without substituting an empty library.
- Rejecting a second same-library connection and orphaned WAL state.
- Rejecting production/arbitrary test paths and separating demo storage.
- Deleting a course while retaining its global paper and the other course association.
- Idempotent assignments and validation of references before mutation.
- Metadata edits preserving user notes, reading state and favorite state.
- Paper deletion removing all memberships while retaining courses.
- Course ordering, description/color editing and duplicate-name validation.

Core Data emits expected errors during the deliberately corrupt-store test; that test passes and verifies the original bytes and backup remain intact. These diagnostic lines are not unexpected test failures.

The 25 independent checks additionally exercise process-level locking, snapshot publication, byte-for-byte retention of SQLite/WAL/SHM, localization and recovery of a committed annotation from a real WAL left by an exited writer. Automated test files use unique temporary directories, never production storage.

## Issues found and fixed

The initial native Xcode targets requested both Intel and Apple Silicon outputs while the local package dependencies built only for the active Mac. Both configurations now explicitly use `ONLY_ACTIVE_ARCH = YES`, matching the single-Mac scope. After this change, Debug/test/Release builds succeeded.

The first packaging attempt placed the Swift package resource bundle in the app root, which `codesign` rejected as unsealed content. The bundle is now assembled in a clean staging directory, with resources under `Contents/Resources`, and published only after signing and verification succeed. The final signature was checked again at the destination path.

## Native review and remaining limits

The actual Italian interface was launched from the shared Xcode scheme after verifying `--demo` was enabled. Two courses named `Milestone 1 · Robotica` and `Milestone 1 · Visione` were created. A paper named `Milestone 1 — Local Research Library` was entered using Command-N, with two ordered authors and an abstract, and assigned to both courses. The table and sidebar showed one global paper and one membership in each course. A subsequent process restart displayed the same data. The demo fixtures are retained for review; production was not opened.

Selecting a table row by mouse or keyboard causes the external `SkyComputerUseService` to terminate. Its macOS crash report identifies `EXC_BREAKPOINT`/`SIGTRAP` with `Array.remove(at:)` in the failing stack. Paper Library remains running in Xcode; no PaperLibrary crash report was found. Resetting the automation session, restarting the app and disabling snapshot diffing did not resolve the automation failure. This evidence identifies an automation-service crash; it does not establish that every inspector interaction works correctly.

Notes editing through the inspector, failed-write termination handling, native contextual deletion/reordering, the complete filter/selection checklist, packaged-app launch and the Debug-to-Release runtime replacement drill remain unverified through the native UI. Their repository behaviors are tested where listed above. No large-library benchmark, portable backup/recovery drill, PDF functionality or AI functionality is claimed.

Xcode test result bundles are under `build/DerivedData/Logs/Test/`; the successful action is `Run-PaperLibrary-2026.11.13_19-22-40-+0100.xcresult`. Temporary build logs are `/tmp/paperlibrary-m1-verification.log` and `/tmp/paperlibrary-m1-packaging.log`.

## Next checkpoint

Complete the remaining interaction checks in [MILESTONES.md](../MILESTONES.md), using a working native automation session or manual review on the Mac. Keep milestone 1 open until those checks are resolved; arXiv import remains milestone 2.
