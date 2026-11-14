import PaperLibraryCore
import PaperLibrarySupport
import SwiftUI

public struct LibraryPaperTable: View {
    private static let rowContentHeight: CGFloat = 62
    public let papers: [Paper]
    public let pdfRecordIDs: [UUID: UUID]
    @Binding private var selection: Set<UUID>
    @Binding private var sortOrder: [KeyPathComparator<Paper>]
    private let openPDF: (UUID) -> Void

    public init(papers: [Paper], pdfRecordIDs: [UUID: UUID], selection: Binding<Set<UUID>>, sortOrder: Binding<[KeyPathComparator<Paper>]>, openPDF: @escaping (UUID) -> Void) {
        self.papers = papers; self.pdfRecordIDs = pdfRecordIDs
        self._selection = selection; self._sortOrder = sortOrder; self.openPDF = openPDF
    }

    public var body: some View {
        Table(papers, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(Strings.text("paper.title"), value: \Paper.title) { paper in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(paper.title).fontWeight(.medium)
                            .lineLimit(2, reservesSpace: true)
                        Text(paper.authors.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if paper.isFavorite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                            .accessibilityLabel(Strings.text("paper.favorite"))
                    }
                    if let recordID = pdfRecordIDs[paper.id] {
                        Button { openPDF(recordID) } label: {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).help(Strings.text("pdf.open"))
                            .accessibilityLabel(Strings.text("pdf.open"))
                    }
                }.frame(height: Self.rowContentHeight).clipped()
                    .help(paper.title + "\n" + paper.authors.joined(separator: ", "))
            }.width(min: 250, ideal: 420)
            TableColumn(Strings.text("paper.status"), value: \Paper.readingStatusRaw) { paper in
                Text(paper.readingStatus.localizedName)
                    .lineLimit(1)
                    .frame(height: Self.rowContentHeight, alignment: .leading)
            }.width(90)
            TableColumn(Strings.text("paper.added"), value: \Paper.createdAt) { paper in
                Text(paper.createdAt, format: .dateTime.day().month().year())
                    .lineLimit(1)
                    .frame(height: Self.rowContentHeight, alignment: .leading)
            }.width(95)
        }
    }
}
