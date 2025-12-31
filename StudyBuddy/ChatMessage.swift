import Foundation

struct PDFReference: Identifiable, Codable {
    var id = UUID()
    var pageNumber: Int
    var text: String
    var relevanceScore: Float
}

struct ChatMessage: Identifiable {
    var id = UUID()
    var text: String
    var isUser: Bool
    var context: String? = nil
    var references: [PDFReference] = []
}
