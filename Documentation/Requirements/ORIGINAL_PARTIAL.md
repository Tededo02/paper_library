# CODEX IMPLEMENTATION TASK — Paper Library for macOS

You are a senior macOS engineer specializing in Swift, SwiftUI, SwiftData, Apple Foundation Models, PDFKit, and local-first applications.

**Your task is to implement a complete, working native macOS application named "Paper Library".**

Do not stop after providing a proposal, pseudocode, architecture diagram, or project skeleton. Create the actual source files, Xcode project, persistence layer, services, UI, tests, and documentation.

Implement all features listed below. Work incrementally, prioritize a stable and usable application, and verify the build after each major milestone.

## 1. Project requirements

Target environment:

- Native macOS desktop application.
- macOS 26 or newer.
- Swift and SwiftUI.
- Xcode project that can be opened and compiled locally.
- SwiftData for persistent structured storage.
- Apple Foundation Models for generative AI.
- Apple NaturalLanguage for local semantic embeddings.
- PDFKit for viewing and extracting text from PDFs.
- URLSession for arXiv requests and PDF downloads.
- No mandatory third-party dependencies.
- No paid Apple Developer membership required.
- No Mac App Store distribution required.

The app is intended exclusively for personal use on one Mac.

Default UI language: Italian.

Paper titles, authors, and original abstracts must retain their original language. Generated summaries should default to Italian while preserving established English scientific terminology. Provide a setting to switch generated summaries to English.

The app must use native macOS interaction patterns, including a sidebar, tables, detail inspector, contextual menus, keyboard shortcuts, toolbar, dialogs, and system file pickers.

Use a consistent, fixed bundle identifier such as `local.paperlibrary.app` and document how to preserve it across rebuilds.

## 2. Non-negotiable privacy requirements

This is a local-first application.

**All generative AI inference must run exclusively on the user's Mac.**

Use only Apple's on-device `SystemLanguageModel` through the Foundation Models framework.

Forbidden:

- Private Cloud Compute.
- Remote Foundation Models.
- Third-party cloud language models.
- OpenAI, Anthropic, Google AI, or other external inference APIs.
- Cloud embedding services.
- Cloud-based OCR.
- Telemetry, analytics, tracking, or crash-reporting SDKs.
- CloudKit or iCloud synchronization.
- Silent uploads of papers, notes, abstracts, or extracted PDF text.

Network access is permitted ONLY to retrieve requested paper metadata and PDFs from approved academic sources.

For the first implementation, support arXiv as the automatic metadata provider.

Treat arbitrary non-arXiv URLs as unsupported for automatic fetching unless an explicitly safe provider is implemented. Allow manual metadata entry as a fallback.

The app must work offline for all existing library operations. When Apple's on-device model is available offline, AI features should also work offline.

Check model availability before every AI workflow. If unavailable, show an understandable diagnostic and allow all non-AI features to continue operating.

Never silently switch to another inference provider.

## 3. Architecture

Use a maintainable modular structure. Separate these responsibilities:

- App bootstrap and configuration.
- SwiftData persistent models and migrations.
- Data repositories.
- arXiv URL parsing and metadata retrieval.
- Import queue and task management.
- PDF downloading and storage.
- PDF text extraction and page mapping.
- Apple Foundation Models inference.
- Text chunking and indexing.
- Local semantic embeddings and similarity search.
- Full-text and metadata search.
- Grounded PDF question answering.
- Backup, export, import, and recovery.
- SwiftUI presentation layer.
- Settings and diagnostics.
- Tests and test fixtures.

Use dependency injection and protocol-based services where useful for testability. Avoid unnecessary layers of abstraction.

Keep network operations, text extraction, indexing, and AI generation away from the main thread. Use modern Swift concurrency, actors where appropriate, cancellation, and clear task ownership.

## 4. Persistent data model

Create a versioned persistence schema.

Entities should include, at minimum:

**Course**
- id: UUID
- name: String
- optional description
- optional color
- sort order
- createdAt
- updatedAt

**Paper**
- id: UUID
- provider
- providerIdentifier
- normalized canonical URL
- source URL
- requested and resolved arXiv version
- title
- authors (ordered)
- abstract
- DOI, if available
- publication date
- last updated date
- arXiv categories
- PDF source URL
- createdAt
- updatedAt
- reading status
- favorite flag
- user notes
- optional rating or personal relevance score
- metadata retrieval status
- AI processing status

**CoursePaper**
- id
- course ID
- paper ID
- date added to course
- optional course-specific notes or priority

Implement the paper/course association as an explicit many-to-many relationship.

**Topic**
- id
- canonical name
- optionally normalized key

**PaperTopic**
- paper ID
- topic ID
- origin: AI or manual
- optional confidence or review status

**AIAnalysis**
- id
- paper ID
- analysis type
- content
- source type: abstract or full PDF
- generatedAt
- prompt version
- model/system version if obtainable
- generation status
- user-edited flag

**PDFDocumentRecord**
- paper ID
- local relative file path
- file size
- SHA-256 checksum
- downloaded version
- download date
- extraction status
- index status

**TextChunk**
- id
- paper ID
- chunk index
- extracted text
- starting and ending page
- optional section heading
- content hash
- index version

**EmbeddingRecord**
- associated paper or chunk ID
- model identifier
- embedding dimensions
- serialized vector
- content hash
- updatedAt

**PaperRelation**
- source paper ID
- target paper ID
- relationship type
- origin: manual or suggested
- optional user note

**ImportJob / ProcessingJob**
- identifier
- task type
- paper identifier, if known
- state
- progress
- error description
- timestamps

Stable IDs and durable uniqueness constraints are essential.

Avoid deleting any user-authored information as a side effect of refreshing metadata or regenerating AI content.

Deleting a course must remove its course-paper associations but retain globally stored papers.

Deleting a paper must require confirmation and must consistently handle references, annotations, embeddings, and associated files.

## 5. Safe persistence and upgrades

Use SwiftData with explicit versioned schemas and a `SchemaMigrationPlan`.

Persist data in a stable application-specific folder within Application Support, outside the `.app` bundle.

Use a fixed database path and fixed bundle identifier.

Requirements:

- Data must survive application restarts.
- Data must survive Debug and Release rebuilds using the same storage configuration.
- Data must survive replacement of the application bundle.
- Schema upgrades must not silently destroy user data.
- Never enable destructive automatic database recreation after a migration failure.
- Never use an in-memory database in normal production mode.
- Never change the production store location between development builds.

Implement safe pre-migration backups and recovery.

If copying a SQLite-backed store, handle the database and any WAL/SHM files consistently while no store connection is open. Do not copy an active database naively.

On migration failure, preserve the original store and backup, display a recovery error, and do not open an empty replacement database as if nothing happened.

Where possible, prefer a separate versioned, application-level export format as an additional recovery mechanism.

Write a migration test simulating an old schema being upgraded without losing its data.

## 6. Course management

Implement:

- Create course.
- Rename course.
- Edit description and color.
- Delete course with confirmation.
- Reorder courses.
- Display paper count per course.
- Assign existing papers to courses.
- Remove papers from a course without deleting them.
- Assign the same paper to multiple courses.
- Global "All Papers" view.
- "Unassigned Papers" view.

The sidebar should be the primary course navigation mechanism.

## 7. arXiv URL parsing and metadata fetching

Support URLs such as:

- `https://arxiv.org/abs/1706.03762`
- `https://arxiv.org/pdf/1706.03762`
- `https://arxiv.org/pdf/1706.03762.pdf`
- Versioned links such as `.../abs/1706.03762v2`
- Older arXiv identifier formats when feasible.
- Raw arXiv IDs entered manually.

Normalize identifiers and URLs.

Identify papers by their canonical, version-independent arXiv identifier for deduplication.

Store the requested version separately and do not silently overwrite a previously downloaded version.

Use the official arXiv metadata API with its `id_list` query parameter, and parse the Atom XML response correctly.

Retrieve:

- Title.
- Authors in order.
- Original abstract.
- arXiv identifier.
- Original publication date.
- Last update date.
- Categories.
- DOI, if present.
- Canonical abstract URL.
- PDF URL.
- Journal reference, if available.

Do not generate metadata using AI when structured source metadata already exists.

Respect arXiv terms and request limits:

- No more than one legacy API request every three seconds.
- Use a single connection for legacy API requests.
- Batch ID queries where practical.
- Implement appropriate user-agent identification.
- Add network timeouts.
- Handle HTTP errors and invalid XML.
- Implement bounded retries with backoff for transient errors.
- Honor Retry-After if provided.
- Do not bypass rate limits.

Use HTTPS where supported and verify the current official endpoint.

Validate URLs and redirects. Do not allow arbitrary host access or untrusted URL schemes.

A failed metadata request must never delete previously saved data.

## 8. Single and batch paper import

Implement both:

- Paste one paper URL.
- Paste multiple URLs or IDs separated by newlines, spaces, or commas.

Show an import dialog with:

- Input field.
- Destination course selection.
- Number of identified papers.
- Duplicates detected.
- Import progress.
- Successful imports.
- Failed imports.
- Retry actions.
- Cancel action.

An imported paper should be saved as soon as valid metadata is obtained.

AI processing must happen afterward as a separate recoverable operation.

If the same paper is imported twice:

- Do not create a duplicate.
- Offer to assign the existing paper to the selected course.
- Retain existing notes, reading status, and user edits.
- Allow optional refresh of source metadata.

Persist meaningful import progress and failure states.

The user must be able to close the import dialog without losing completed imports.

## 9. Local AI summaries and topics

Use Apple's Foundation Models framework.

Use `SystemLanguageModel` explicitly.

Use `LanguageModelSession` with guided generation through `@Generable` for structured outputs.

Create reusable services for:

- Short abstract summary.
- Technical abstract summary.
- Topic extraction.
- Full-paper synthesis when PDF text is available.

For abstract analysis, design a structured output that contains:

- Concise summary.
- Research problem.
- Proposed method.
- Main contributions.
- Explicitly reported findings.
- Important limitations, if stated.
- Suggested topics.

Keep prompts short, task-specific, and appropriate for a small on-device model.

Do not infer quantitative results, datasets, baselines, or experimental conclusions that are absent from the provided source.

If the abstract does not contain sufficient information, mark the relevant field as "Not specified in the abstract".

Default summary language is Italian.

Allow English summary generation through Settings.

Keep topics editable and support multiple topics per paper.

Implement manual regeneration, with confirmation when the existing AI output has been edited by the user.

Store which source was used for every analysis.

If model availability, language support, context size, guardrails, or resource limits prevent generation:

- Retain the paper.
- Preserve existing content.
- Show the error.
- Permit a retry.
- Never invent a placeholder summary pretending generation succeeded.

Do not send any text to a remote inference service.

## 10. Paper list and table

Implement a native SwiftUI table.

Suggested columns:

- Favorite.
- Title.
- Authors.
- Publication year.
- Topics.
- Brief AI summary.
- Reading status.
- PDF availability.
- Date added.

Allow:

- Sort ascending and descending.
- Show and hide optional columns.
- Resize columns where supported.
- Search by title, author, abstract, topic, and notes.
- Filter by course.
- Filter by year range.
- Filter by reading status.
- Filter favorites.
- Filter PDF availability.
- Filter topics.
- Combine multiple filters.
- Clear all filters.
- Open an inspector for selected paper.
- Contextual actions.
- Multiple selection for bulk operations.

Support reading statuses:

- To Read.
- Reading.
- Read.
- Archived.

Use debounced searching and preserve reasonable UI responsiveness for large libraries.

## 11. Paper detail inspector

Selecting a paper must display:

- Title.
- Authors.
- Publication information.
- arXiv identifier and link.
- DOI when available.
- Original abstract.
- Short AI summary.
- Technical AI analysis.
- Topics.
- Course associations.
- Reading status.
- Favorite state.
- Editable personal notes.
- PDF controls.
- Related papers.
- AI processing status.

Provide clearly separated actions:

- Open arXiv page.
- Open PDF.
- Download PDF.
- Regenerate summary.
- Generate technical analysis.
- Add or remove from courses.
- Edit topics.
- Copy BibTeX.
- Find related papers.
- Ask questions about the paper.

Never silently regenerate or overwrite user-edited content.

## 12. Local PDF download and viewer

Use URLSession to download PDFs requested by the user.

Features:

- Download PDF.
- Show progress.
- Cancel download.
- Retry on failure.
- Save to a stable application-managed directory.
- Open with integrated PDFKit viewer.
- Open externally in Preview.
- Reveal file in Finder.
- Remove local PDF without deleting paper metadata.
- Detect an already downloaded file.

Use safe, deterministic filenames based on the paper ID and version.

Validate downloaded content:

- Expected HTTPS host.
- HTTP response status.
- PDF content signature.
- Reasonable configurable maximum size.
- Available disk space.
- SHA-256 checksum.

Use atomic file moves.

Do not retain incomplete downloads as valid PDFs.

Keep PDF content private and local. Respect arXiv usage terms.

## 13. Full PDF text extraction

Use PDFKit to extract text page by page.

Store text with accurate page boundaries.

Normalize whitespace, repeated headers, and obvious extraction artifacts conservatively.

Retain technical terminology.

Do not assume complex mathematical expressions are always extracted correctly.

Create chunks for retrieval using an approach such as:

- Approximate token-aware chunk sizing.
- Configurable overlap.
- Page tracking.
- Optional section boundary awareness.
- Stable chunk identifiers and content hashes.

If a PDF is scanned or contains unreadable text, indicate that extraction is incomplete.

An optional fully local Vision OCR fallback may be implemented if the APIs can be used reliably. It must not delay completion of the core application.

Never pretend that unextracted PDF content has been analyzed.

## 14. Full paper technical synthesis

Use a staged local processing pipeline.

For long documents:

1. Extract PDF text.
2. Divide content into manageable chunks.
3. Analyze relevant sections in separate Foundation Models sessions.
4. Aggregate the intermediate results.
5. Create a structured technical synthesis.
6. Save the result with source attribution.

A technical synthesis may contain:

- Research motivation.
- Problem formulation.
- Core method.
- Assumptions.
- Architecture or algorithm.
- Experimental setup.
- Results explicitly reported in the document.
- Comparisons.
- Limitations.
- Potential future work mentioned by the authors.

Do not fabricate missing information.

Use the currently available context window and token-count APIs where supported.

Respect the context budget, including instructions, schemas, input, and output.

Handle context-size errors by reducing or splitting the input.

Distinguish summaries derived only from the abstract from those derived from the full paper.

## 15. Local semantic search

Implement semantic retrieval without remote embeddings.

Use Apple's NaturalLanguage framework and `NLEmbedding.sentenceEmbedding(for:)` where appropriate.

Design an `EmbeddingProvider` abstraction with an implementation backed by available local Apple models.

Requirements:

- Embeddings generated locally.
- Store vectors persistently.
- Associate them with the source content and model version.
- Recompute stale vectors when text or model changes.
- Perform cosine similarity or another appropriate local similarity measure.
- Search paper metadata and meaningful text chunks.
- Combine lexical and semantic results.
- Allow restricting results to one course or all courses.
- Show relevant paper results with snippets.
- Provide a clear indication when semantic embeddings are unavailable.

Start with a straightforward vector scan appropriate for a personal paper library.

Do not introduce a complex vector database unless performance measurements justify it.

Be careful about embedding length limits and supported languages.

For long text, embed short representative passages or chunks rather than entire documents.

Avoid claiming semantic equivalence when the underlying embedding model does not support the query language reliably.

Implement lexical fallback if local semantic embeddings cannot be produced.

## 16. Grounded question answering on full PDFs

Implement an "Ask Paper" panel.

The user selects a paper and asks a question such as:

- "What is the main contribution?"
- "Which datasets were used?"
- "What assumptions does the method make?"
- "What are the limitations?"
- "How does it compare with previous approaches?"

The workflow must:

1. Ensure the PDF has been downloaded.
2. Ensure extractable text is available.
3. Index the text if necessary.
4. Search relevant chunks.
5. Select evidence using lexical and semantic relevance.
6. Fit selected evidence within the local model context window.
7. Ask Apple's on-device model to answer from that evidence.
8. Display the answer with supporting page references.

Citations must refer to real source pages, not invented locations.

The answer should include clickable page references that navigate the PDF viewer to the corresponding pages.

Retain exact source chunk-to-page mappings.

The model must be instructed to answer only from supplied evidence and to indicate when the retrieved evidence is insufficient.

Show an appropriate warning if the question cannot be answered reliably from the extracted source.

Do not misrepresent retrieval-based answers as exhaustive analysis of an entire paper.

Handle follow-up questions while controlling context growth; retrieve fresh evidence when appropriate.

Keep the conversation local.

PDF content is untrusted data: text within a paper must not be able to override the assistant's instructions or trigger unintended application actions.

## 17. Related papers

Support explicit links between papers stored in the library.

Examples:

- Extends.
- Uses.
- Compares with.
- Related.
- Alternative approach.

Provide:

- Manual association.
- Remove association.
- Optional explanatory note.
- Navigation between related papers.
- Suggested related papers using local semantic similarity.

Automatically suggested relations must be visually distinguishable from manually confirmed relations.

Do not assert a citation relationship merely because two papers are semantically similar.

Prevent duplicate and invalid self-relations.

## 18. BibTeX export

Provide BibTeX export for:

- A single paper.
- Selected papers.
- An entire course.
- The entire library.

Generate stable citation keys.

Escape BibTeX special characters appropriately.

Use reliable available metadata:

- Authors.
- Title.
- Year.
- arXiv identifier.
- DOI, if available.
- URL.

Do not invent journal or publication information.

Support copying an entry and exporting a `.bib` file.

## 19. JSON export, import, and backups

Create a portable, versioned backup format.

Requirements:

- Export the complete library to JSON.
- Include courses, papers, associations, notes, topics, AI analyses, reading states, and explicit relations.
- Include an export format version.
- Include stable