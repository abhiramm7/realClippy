

import Foundation
import PDFKit

// NOTE:
// This file is kept as a reference copy of `TextSearchService`.
// It must NOT be compiled alongside the real `TextSearchService.swift`.
// Renamed to avoid duplicate type definitions.

struct SearchResult_RefCopy: Identifiable {
    var id = UUID()
    var pageNumber: Int
    var matchText: String
    var context: String
    var matchRange: NSRange
}

final class TextSearchService_RefCopy {
    // Intentionally empty reference copy.
}
