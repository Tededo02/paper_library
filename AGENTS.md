# Project instructions

- Use `#` for comments and write comments in English. Ask for clarification before acting if the user's request is ambiguous.
- Keep exactly one persistent application bundle at `build/release/Paper Library.app`. Debug, Release and future updates must replace this same app, not create another user-facing app.
- Preserve the fixed bundle identifier and the Application Support library. Removing app copies must never remove database files, PDFs, notes or backups.
- Use `Scripts/verify.sh` for native verification; it isolates temporary app products and cleans them up. Preserve this isolation when changing the build workflow.
- Before delivery after an app build, run `python3 Scripts/check_single_app.py` and verify the final app signature. Keep the generator, shared scheme and packaging script consistent with the single-app path.
