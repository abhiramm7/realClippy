import SwiftUI
import PDFKit

struct PDFContainerView: View {
    @Binding var url: URL?
    @Binding var pdfView: PDFView?

    var body: some View {
        PDFKitViewWithReference(url: $url, pdfView: $pdfView)
    }
}
