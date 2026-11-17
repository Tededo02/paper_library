# DOI imports

Verified on 17 November 2026: all 118 tests passed under Swift Package Manager and Xcode; native Debug and Release builds succeeded. Both supplied DOI links passed the live import and duplicate checks. The Release app was packaged at `build/release/Paper Library.app`; the single-app inventory and strict signature verification passed with bundle identifier `local.paperlibrary.app`.

The Add Papers link input accepts mixed arXiv identifiers and DOIs, including bare DOIs, `doi:` prefixes, `doi.org` and `dx.doi.org` URLs, percent-encoded paths and the escaped scheme spelling in the supplied examples. DOI normalization folds case. Batch parsing deduplicates normalized inputs while keeping failed rows visible.

`ImportIdentifier` distinguishes the two providers. Existing job columns store the canonical identifier and optional arXiv version, so the persisted schema and existing library need no migration. Interrupted DOI jobs are recovered through the existing explicit retry flow.

The DOI client requests JSON only from fixed Crossref endpoints, then DataCite when Crossref reports 404. It validates the returned DOI, requires a title, and tolerates missing optional metadata. Ordered authors, publication dates, journal references and abstracts are retained when supplied; metadata markup is converted to plain text. A partial refresh preserves previously retrieved optional fields. The service documentation is available from [Crossref](https://www.crossref.org/documentation/retrieve-metadata/rest-api/) and [DataCite](https://support.datacite.org/docs/rest-api).

Requests use an ephemeral session without cookie storage, credentials or caching. Both advertised and streamed metadata responses are limited to 2 MiB; redirects are rejected. Transient failures have bounded retries and respect Retry-After. The existing import worker serializes DOI requests and isolates failures by job. Network errors never create a paper without valid metadata.

DOI imports reuse existing normalized identities or a paper already carrying the DOI. Importing arXiv metadata can reuse a DOI or manual record, while distinct arXiv identities remain distinct. Notes, favorites, reading state, courses and manually edited metadata retain their existing protection. Refreshing a paper matched by DOI preserves its arXiv or local PDF source identity. Deletion also cancels pending DOI jobs matching the deleted paper.

The detail view links to the DOI resolver. DOI import retrieves metadata; it does not download publisher PDFs. The existing arXiv PDF download policy is unchanged.

## Verification

- `bash Scripts/verify.sh` runs configuration checks, storage safety checks, Swift package tests, native Xcode tests, and Debug and Release builds in isolated temporary app directories.
- DOI regression tests cover normalization, mixed batches, provider fallback, absent metadata, identity mismatch, retries, network policy, redirects, advertised and streamed response limits, persistence, interruption, cancellation, duplicate handling and protected refreshes.
- `.build/debug/DOILiveCheck --live` imports both supplied DOI links into a disposable library through the production client, checks their authors and available metadata, then reimports a DOI to verify deduplication and preserved notes and course assignments.
- `bash Scripts/build-app.sh release` publishes the signed app at the single canonical path. `python3 Scripts/check_single_app.py` and `codesign --verify --deep --strict "build/release/Paper Library.app"` check the final artifact.

The live check never opens the production library or invokes PDFs or AI. Native interface compilation is verified; the DOI entry workflow has not been reviewed through interactive UI automation.
