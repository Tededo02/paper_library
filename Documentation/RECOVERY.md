# Recovery and safe upgrades

## Startup behavior

Paper Library never deletes an unreadable database and never opens a new empty library as a recovery substitute. Startup failures show the actual store path, the diagnostic and the snapshot path when one was created. A second instance is rejected before snapshotting or connecting to the store.

Each existing-store startup first takes a snapshot while no application connection is open. A snapshot contains `Store/` and `snapshot.json`. The Store directory includes the main database plus any existing WAL/SHM and support files. The manifest's `applicationSchema` identifies the application that took the snapshot; it does not assert that an older source store had already been migrated.

Schema V5 preserves PDF document records, jobs, page text and chunks, and adds analyses, AI jobs, profiles and topics. Preflight snapshots preserve those database rows but do not copy the files in `PDFs/`. For a manual full-library backup, quit every app instance and copy the entire Application Support root, including `Store/` and `PDFs/`, together. Keep an independent copy before attempting recovery; portable versioned backup/restore is still milestone 5 work.

## Recovering a snapshot manually

1. Quit every Paper Library process. Confirm no other process has the library open. Do not bypass the lock or copy an active store.
2. Identify the correct root: production and demo are separate. Use the path displayed by diagnostics rather than guessing.
3. Make an additional copy of the **entire failed Store directory** outside that root. Preserve it, its WAL/SHM files and the failed migration diagnostic for investigation.
4. Choose an intact `Backups/preflight-…` snapshot. Keep the original snapshot unchanged. Its `Store` directory must be restored as a unit; never mix one snapshot's database with another snapshot's WAL/SHM.
5. Move the existing Store directory aside. Copy the selected snapshot's Store directory into the original root with the exact name `Store`.
6. Reopen the app with a version whose migration plan supports the snapshot schema. Verify paper/course counts, notes, assignments and any available PDFs before using the library normally. If opening still fails, stop and preserve all copies. Restoring only database rows cannot recover PDF bytes that were separately removed.

The advisory `library.lock` file is intentionally persistent; its existence alone does not mean the app is running. The OS releases the lock when the owning process exits. Deleting this file while an app is running could permit another process to bypass the lock, so do not delete it during recovery.

## Current limits

The preflight snapshot protects structured database content. It is not yet a portable JSON export, a full-library backup including PDF files, or an externally stored disaster-recovery copy. Snapshots currently accumulate without automatic pruning. Migration tests from V1, V2, V3 and V4 through the current V5 plan, reopening and corrupt-store preservation have passed with full Xcode; the independent file-safety checks also recover real SQLite WAL data. The full manual recovery drill remains unperformed.

Interrupted PDF jobs require explicit retry and restart downloads from the beginning. Startup maintenance removes owned stale `.part` files, not complete unreferenced PDFs. A crash after atomic file publication but before database commit can leave an unreferenced complete PDF; preserve it when diagnosing recovery. Confirmed PDF removals use database tombstones and retry physical cleanup later. Modified PDF files fail checksum verification without being overwritten; reveal them in Finder to keep a copy before choosing confirmed removal.

Unfinished AI jobs become interrupted on launch and never restart automatically. Explicit retry creates a fresh attempt against the current source/profile. Intermediate model output is not a recovery checkpoint. Previously saved analyses, original evidence, personal corrections and manual topic choices remain stored independently of a failed job. Removing a PDF retains its analysis history but removes the source text needed to regenerate it; the saved page references may no longer open until the corresponding source is available again.
