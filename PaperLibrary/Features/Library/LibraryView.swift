import PaperLibraryCore
import PaperLibrarySupport
import PaperLibraryUI
import SwiftUI

private enum LibraryScope: Hashable {
    case all, favorites, unassigned, unread, recent, course(UUID)
}

struct LibraryView: View {
    @Bindable var state: ApplicationState
    let repository: LibraryRepository
    @State private var scope: LibraryScope? = .all
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchInput = ""
    @State private var search = ""
    @State private var status: ReadingStatus?
    @State private var favoritesOnly = false
    @State private var sortOrder = [KeyPathComparator(\Paper.title)]
    @State private var inspectorVisible = true
    @State private var showCourseForm = false
    @State private var editingCourse: Course?
    @State private var editingPaper: Paper?
    @State private var courseToDelete: Course?
    @State private var confirmPaperDelete = false
    @FocusState private var searchFocused: Bool

    private var destinationCourse: UUID? {
        if case let .course(id) = scope { return id }
        return nil
    }

    private var title: String {
        switch scope ?? .all {
        case .all: Strings.text("sidebar.all")
        case .favorites: Strings.text("sidebar.favorites")
        case .unassigned: Strings.text("sidebar.unassigned")
        case .unread: Strings.text("sidebar.unread")
        case .recent: Strings.text("sidebar.recent")
        case .course(let id): repository.course(id: id)?.name ?? Strings.text("sidebar.all")
        }
    }

    private var visiblePapers: [Paper] {
        let assigned = Set(repository.memberships.map(\.paperID))
        let inCourse = Set(repository.memberships.filter { $0.courseID == destinationCourse }.map(\.paperID))
        return repository.papers.filter { paper in
            switch scope ?? .all {
            case .all: break
            case .favorites: if !paper.isFavorite { return false }
            case .unassigned: if assigned.contains(paper.id) { return false }
            case .unread: if paper.readingStatus != .toRead { return false }
            case .recent: if paper.createdAt < Date().addingTimeInterval(-30 * 86_400) { return false }
            case .course: if !inCourse.contains(paper.id) { return false }
            }
            if let status, paper.readingStatus != status { return false }
            if favoritesOnly && !paper.isFavorite { return false }
            if !search.isEmpty {
                let text = [paper.title, paper.authors.joined(separator: " "), paper.abstract, paper.notes].joined(separator: "\n")
                return text.localizedStandardContains(search)
            }
            return true
        }.sorted(using: sortOrder)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } detail: {
            paperTable
            .navigationTitle(title)
            .navigationSubtitle("\(visiblePapers.count) \(Strings.text("paper.count"))" + (status != nil || favoritesOnly ? " · \(Strings.text("filters.active"))" : "") + (repository.store.configuration.mode == .demo ? " · Demo" : ""))
            .toolbar { toolbar }
            .inspector(isPresented: Binding(get: { inspectorVisible && !selectedIDs.isEmpty }, set: { inspectorVisible = $0 })) {
                inspector
                    .inspectorColumnWidth(min: 300, ideal: 370, max: 520)
            }
        }
        .sheet(isPresented: $state.showAddPaper) {
            PaperForm(repository: repository, paper: nil, destinationCourse: destinationCourse)
        }
        .sheet(isPresented: $state.showImport) {
            if let imports = state.imports, let pdfs = state.pdfs {
                ImportView(coordinator: imports, pdfs: pdfs, destinationCourse: destinationCourse, showHistory: state.showImportHistory) { selectedIDs = [$0] }
            }
        }
        .sheet(isPresented: Binding(get: { state.readerRecordID != nil }, set: { if !$0 { state.readerRecordID = nil } })) {
            if let id = state.readerRecordID, let record = repository.pdfRecord(id: id), let pdfs = state.pdfs {
                PDFReaderView(state: state, repository: repository, pdfs: pdfs, record: record)
            }
        }
        .sheet(item: $editingPaper) { paper in
            PaperForm(repository: repository, paper: paper, destinationCourse: nil)
        }
        .sheet(isPresented: $showCourseForm) {
            CourseForm(repository: repository, course: editingCourse)
        }
        .confirmationDialog(Strings.text("course.delete"), isPresented: Binding(get: { courseToDelete != nil }, set: { if !$0 { courseToDelete = nil } }), titleVisibility: .visible, presenting: courseToDelete) { course in
            Button(Strings.text("action.delete"), role: .destructive) {
                state.perform { try repository.deleteCourse(id: course.id) }
                if destinationCourse == course.id && repository.course(id: course.id) == nil { scope = .all }
                courseToDelete = nil
            }
        } message: { _ in Text(Strings.text("course.deleteMessage")) }
        .confirmationDialog(Strings.text("paper.delete"), isPresented: $confirmPaperDelete, titleVisibility: .visible) {
            Button(Strings.text("action.delete"), role: .destructive) {
                let ids = selectedIDs
                Task {
                    do {
                        try state.ai?.cancel(paperIDs: ids)
                        if let pdfs = state.pdfs { try await pdfs.deletePapers(ids: ids) }
                        else { try repository.deletePapers(ids: ids) }
                        for id in ids { state.pendingNotes.removeValue(forKey: id) }
                    } catch { state.message = error.localizedDescription }
                    selectedIDs = selectedIDs.intersection(Set(repository.papers.map(\.id)))
                }
            }
        } message: { Text(Strings.text("paper.deleteMessage")) }
        .onChange(of: scope) { selectedIDs = [] }
        .onChange(of: selectedIDs) {
            state.selectedPaperID = selectedIDs.count == 1 ? selectedIDs.first : nil
            if !selectedIDs.isEmpty { inspectorVisible = true }
        }
        .onChange(of: state.searchRequest) { searchFocused = true }
        .onChange(of: visiblePapers.map(\.id)) { _, ids in selectedIDs.formIntersection(Set(ids)) }
        .task(id: searchInput) {
            do {
                try await Task.sleep(for: .milliseconds(200))
                search = searchInput.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {}
        }
        .task {
            do { try await state.pdfs?.files.prepare(); try await state.pdfs?.cleanupRemovedFiles() }
            catch is CancellationError {} catch { state.message = error.localizedDescription }
        }
    }

    private var sidebar: some View {
        List(selection: $scope) {
            Section(Strings.text("sidebar.library")) {
                Label(Strings.text("sidebar.all"), systemImage: "books.vertical").tag(LibraryScope.all)
                Label(Strings.text("sidebar.unread"), systemImage: "book.closed").tag(LibraryScope.unread)
                Label(Strings.text("sidebar.favorites"), systemImage: "star").tag(LibraryScope.favorites)
                Label(Strings.text("sidebar.recent"), systemImage: "clock").tag(LibraryScope.recent)
                Label(Strings.text("sidebar.unassigned"), systemImage: "tray").tag(LibraryScope.unassigned)
            }
            Section(Strings.text("sidebar.courses")) {
                ForEach(repository.courses, id: \.id) { course in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(CoursePalette.color(course.color))
                        Text(course.name).lineLimit(1)
                        Spacer()
                        Text(repository.count(courseID: course.id), format: .number).foregroundStyle(.secondary)
                    }
                    .tag(LibraryScope.course(course.id))
                    .contextMenu {
                        Button(Strings.text("course.edit")) { editingCourse = course; showCourseForm = true }
                        Button(Strings.text("course.moveUp")) { state.perform { try repository.moveCourse(id: course.id, offset: -1) } }
                        Button(Strings.text("course.moveDown")) { state.perform { try repository.moveCourse(id: course.id, offset: 1) } }
                        Divider()
                        Button(Strings.text("course.delete"), role: .destructive) { courseToDelete = course }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                if state.imports?.isRunning == true {
                    Button { state.showImportHistory = true; state.showImport = true } label: {
                        HStack {
                            ProgressView().controlSize(.mini)
                            Text(Strings.text("import.running")).font(.caption)
                        }
                    }
                }
                Button { editingCourse = nil; showCourseForm = true } label: {
                    Label(Strings.text("course.new"), systemImage: "folder.badge.plus")
                }
            }
            .buttonStyle(.plain).padding()
        }
    }

    private var filters: some View {
        Menu {
            Picker(Strings.text("paper.status"), selection: $status) {
                Text(Strings.text("filters.allStatuses")).tag(Optional<ReadingStatus>.none)
                ForEach(ReadingStatus.allCases, id: \.self) { Text($0.localizedName).tag(Optional($0)) }
            }
            Toggle(Strings.text("filters.favorites"), isOn: $favoritesOnly)
            if status != nil || favoritesOnly {
                Divider()
                Button(Strings.text("filters.clear")) { status = nil; favoritesOnly = false }
            }
        } label: {
            Label(Strings.text("filters.title"), systemImage: status != nil || favoritesOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }.help(Strings.text("filters.title"))
    }

    private var paperTable: some View {
        LibraryPaperTable(papers: visiblePapers,
                          pdfRecordIDs: Dictionary(uniqueKeysWithValues: visiblePapers.compactMap { paper in repository.pdfRecords(paperID: paper.id).first.map { (paper.id, $0.id) } }),
                          selection: $selectedIDs, sortOrder: $sortOrder,
                          openPDF: { state.readerRecordID = $0 })
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                if ids.count == 1, let id = ids.first, let paper = repository.paper(id: id) {
                    Button(Strings.text("paper.edit")) { editingPaper = paper }
                }
                let allFavorites = ids.allSatisfy { repository.paper(id: $0)?.isFavorite == true }
                Button(Strings.text(allFavorites ? "paper.favoriteRemove" : "paper.favoriteAdd")) { state.perform { try repository.setFavorite(!allFavorites, paperIDs: ids) } }
                Menu(Strings.text("paper.status")) {
                    ForEach(ReadingStatus.allCases, id: \.self) { status in
                        Button(status.localizedName) { state.perform { try repository.setReadingStatus(status, paperIDs: ids) } }
                    }
                }
                Menu(Strings.text("course.assign")) {
                    ForEach(repository.courses, id: \.id) { course in
                        Button(course.name) { state.perform { try repository.assign(paperIDs: ids, to: course.id) } }
                    }
                }.disabled(repository.courses.isEmpty)
                if let courseID = destinationCourse {
                    Button(Strings.text("course.remove")) { state.perform { try repository.remove(paperIDs: ids, from: courseID) } }
                }
                Divider()
                Button(Strings.text("paper.delete"), role: .destructive) { selectedIDs = ids; confirmPaperDelete = true }
            }
        } primaryAction: { ids in
            selectedIDs = ids
            if ids.count == 1, let id = ids.first, let pdf = repository.pdfRecords(paperID: id).first { state.readerRecordID = pdf.id }
            else { inspectorVisible = true }
        }
        .onDeleteCommand { if !selectedIDs.isEmpty { confirmPaperDelete = true } }
        .overlay {
            if visiblePapers.isEmpty {
                ContentUnavailableView {
                    Label(Strings.text(repository.papers.isEmpty ? "library.empty" : "search.empty"), systemImage: "books.vertical")
                } description: {
                    Text(Strings.text(repository.papers.isEmpty ? "library.emptyHint" : "search.emptyHint"))
                } actions: {
                    if repository.papers.isEmpty { Button(Strings.text("import.title")) { state.showImportHistory = false; state.showImport = true } }
                    else if status != nil || favoritesOnly || !searchInput.isEmpty {
                        Button(Strings.text("filters.clear")) { status = nil; favoritesOnly = false; searchInput = ""; search = "" }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(Strings.text("import.title")) { state.showImportHistory = false; state.showImport = true }
                Button(Strings.text("paper.new")) { state.showAddPaper = true }
                Divider()
                Button(Strings.text("import.history")) { state.showImportHistory = true; state.showImport = true }
            } label: { Label(Strings.text("paper.add"), systemImage: "plus") }
                .help(Strings.text("paper.add"))
        }
        ToolbarItem { filters }
        ToolbarItem {
            TextField(Strings.text("search.prompt"), text: $searchInput)
                .textFieldStyle(.roundedBorder).frame(width: 240).focused($searchFocused)
                .accessibilityLabel(Strings.text("search.prompt"))
        }
        ToolbarItem {
            Button { inspectorVisible.toggle() } label: { Label(Strings.text("action.details"), systemImage: "sidebar.right") }
                .disabled(selectedIDs.isEmpty).help(Strings.text("action.details"))
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if selectedIDs.count == 1, let id = selectedIDs.first, let paper = repository.paper(id: id) {
            PaperDetailView(state: state, repository: repository, paper: paper) { editingPaper = paper }
                .id(paper.id)
        } else {
            ContentUnavailableView {
                Label(Strings.text(selectedIDs.isEmpty ? "selection.empty" : "selection.multiple"), systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(Strings.text(selectedIDs.isEmpty ? "selection.hint" : "selection.multipleHint"))
            }
        }
    }
}
