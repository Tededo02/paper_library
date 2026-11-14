import PDFKit

@MainActor
public final class LocalPDFView: PDFView {
    private let actionGuard = PDFActionGuard()
    public override init(frame: NSRect) { super.init(frame: frame); delegate = actionGuard }
    public required init?(coder: NSCoder) { super.init(coder: coder); delegate = actionGuard }
    public override func perform(_ action: PDFAction) {
        guard let document, let action = action as? PDFActionGoTo, action.destination.page?.document === document else { return }
        super.perform(action)
    }
}

@MainActor
private final class PDFActionGuard: NSObject, @preconcurrency PDFViewDelegate {
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
    func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoTo action: PDFActionRemoteGoTo) {}
    func pdfViewPerformPrint(_ sender: PDFView) {}
}
