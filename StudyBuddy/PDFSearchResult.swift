import Foundation
import PDFKit

struct PDFSearchResult: Identifiable {
    let id = UUID()
    let pageNumber: Int
    let selection: PDFSelection
    let snippet: String
}

