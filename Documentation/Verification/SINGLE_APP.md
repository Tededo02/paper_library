# Single application build policy verification

Checkpoint date: 2026-11-14, Europe/Rome.

The user requested one current app and a build workflow that does not leave duplicate installed versions. The two extra 0.4.0 Debug/Release app bundles were unregistered from Launch Services and moved to the system Trash. The retained app is `build/release/Paper Library.app`; library data was not targeted.

Both native configurations now use the same `TARGET_BUILD_DIR` and fixed wrapper name. Swift package dependencies retain their normal shared products directory. The generated Xcode project and shared scheme point to the same app product. The packaging script defaults to Release and publishes either configuration to the canonical path. Project instructions and configuration validation preserve this policy for subsequent changes.

`Scripts/verify.sh` overrides the app destination with a unique temporary directory, then unregisters and deletes its app product on completion, error or a handled interruption. Compiler caches and test result bundles remain available. `Scripts/check_single_app.py` rejects additional bundles with the fixed app identifier in the workspace and this project's default Xcode Derived Data folders; packaging and verification invoke it automatically.

Executed checks:

- Source references, localization, syntax and single-output project/scheme assertions passed.
- The complete gate passed: 25 storage checks, 76 tests under each test runner, Xcode Debug and Release builds, temporary-product cleanup and one remaining persistent app.
- The canonical executable's SHA-256 stayed unchanged across isolated verification.
- Ordinary signed Xcode Debug and Release builds both succeeded at the canonical path; the inventory check found one persistent app after each.
- Explicit Debug packaging and default Release packaging both succeeded at the same path. The final artifact is the signed Release 0.4.0 app, build 5, with the existing icon.
- Final signature and duplicate-app inventory checks passed.

The initial attempt to move the entire configuration products directory also moved package search paths, causing missing-module/resource errors. The final implementation changes only `TARGET_BUILD_DIR`, preserving package lookup paths. The final verification gate passed after that correction.

This policy covers this project's normal build and verification workflows. It does not monitor manually copied apps, restored archives or independent installation tools. No GUI interaction is required for the build-output change; a new interactive Xcode Run session was not exercised.

Logs are `/tmp/paperlibrary-single-app-verification.log`, `/tmp/paperlibrary-single-app-debug.log`, `/tmp/paperlibrary-single-app-release.log`, `/tmp/paperlibrary-single-app-package-debug.log` and `/tmp/paperlibrary-single-app-package-release.log`.
