# Table layout after import

Checkpoint date: 2026-11-14, Europe/Rome. Patch: 0.4.1, build 6. Database schema remains V5.

The user reported overlapping paper rows immediately after an import, with navigation away and back restoring their layout. The table allowed title content to grow between one and two lines while native rows were inserted and resized.

The production table was extracted into the reusable PaperLibraryUI target so the application and a native layout regression test instantiate the same SwiftUI view. Every column now reserves an equal 44-point content frame, including empty PDF cells. Titles reserve two lines, are clipped within that frame and retain their full tooltip. AppKit allocates uniform 52-point rows. The table identity is retained; no data reload, selection reset or navigation workaround is used.

## Executed checks

- Before applying the layout change, the new native regression test failed. Its actual NSTableView measured a mix of 24-point and 40-point rows after imports.
- After the fix, the same test measured 52-point rows throughout initial insertion, batch metadata import, title edits, window resizing and deletion. Cell bounds stayed inside their rows. The table instance, selected paper and manually resized title column were retained.
- The fixture uses an offscreen NSHostingView, the actual production table, a temporary SwiftData library and the real import coordinator with an injected metadata provider. It never opens or edits production data and makes no network request.
- The complete verification gate passed: 25 storage checks, **77 tests in 11 suites** under both Swift Package Manager and Xcode, and Debug/Release builds.
- The single-app check passed after temporary verification products were cleaned up.
- Release packaging replaced `build/release/Paper Library.app` with version 0.4.1, build 6. The icon is retained and strict signature verification passed.

The app was quit normally, updated at the same bundle path and reopened. Its accessibility tree retained the original three papers and courses; the table context menu exposed metadata, favorite, reading-state, assignment and deletion actions. The original course view was restored without inserting test papers into the active library. ScreenCaptureKit rejected screenshot capture in this session, so no new live screenshot comparison is claimed. Native frame assertions provide the layout regression evidence. The prior broader interface-review checklist remains separate from this targeted fix.

Commands:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TableLayoutTests --scratch-path .build --cache-path .build/cache
bash Scripts/verify.sh
bash Scripts/build-app.sh release
python3 Scripts/check_single_app.py
codesign --verify --deep --strict 'build/release/Paper Library.app'
```

Logs: `/tmp/paperlibrary-table-baseline.log`, `/tmp/paperlibrary-table-fixed.log`, `/tmp/paperlibrary-table-verification.log`, `/tmp/paperlibrary-table-packaging.log`.
