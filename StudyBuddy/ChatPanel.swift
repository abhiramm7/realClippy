import SwiftUI

struct MultilineText: View {
    let text: String
    let isMarkdown: Bool

    init(_ text: String, isMarkdown: Bool = false) {
        self.text = text
        self.isMarkdown = isMarkdown
    }

    var body: some View {
        let lines = text.components(separatedBy: "\n")

        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(" ")
                        .font(.body)
                } else {
                    if isMarkdown, let attributed = try? AttributedString(markdown: line) {
                        Text(attributed)
                            .font(.body)
                    } else {
                        Text(line)
                            .font(.body)
                    }
                }
            }
        }
    }
}

struct ChatPanel: View {
    @Binding var chatMessages: [ChatMessage]
    @Binding var newMessage: String
    @Binding var isLoading: Bool
    @Binding var selectedContext: String?
    @Binding var ollamaModel: String
    @Binding var useRAG: Bool
    @ObservedObject var searchService: TextSearchService
    var sendMessage: () -> Void
    var stopMessage: () -> Void

    private var bubbleMaxWidth: CGFloat {
        ConfigManager.shared.chatBubbleMaxWidth
    }

    private let maxVisibleReferencePages: Int = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let shouldShowConversation = !chatMessages.isEmpty || !newMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading

            if !shouldShowConversation {
                Spacer()
                VStack(spacing: 8) {
                    Text("Ask me anything about this PDF")
                        .foregroundColor(.secondary)
                        .font(.title3)
                        .multilineTextAlignment(.center)

                    if useRAG {
                        Text("✓ Context search enabled")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(chatMessages) { message in
                                VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                                    HStack {
                                        if message.isUser {
                                            Spacer()
                                            MultilineText(message.text)
                                                .padding(12)
                                                .background(Color.accentColor.opacity(0.15))
                                                .cornerRadius(16)
                                                .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
                                        } else {
                                            MultilineText(message.text, isMarkdown: true)
                                                .padding(12)
                                                .background(Color.gray.opacity(0.1))
                                                .cornerRadius(16)
                                                .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
                                            Spacer()
                                        }
                                    }

                                    // Show references for user messages when using RAG
                                    if message.isUser && !message.references.isEmpty {
                                        let refs = message.references
                                        let visibleRefs = Array(refs.prefix(maxVisibleReferencePages))
                                        let remainingCount = max(0, refs.count - visibleRefs.count)

                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text("📄 Pages")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)

                                            VStack(alignment: .trailing, spacing: 2) {
                                                ForEach(visibleRefs) { ref in
                                                    Text("Page \(ref.pageNumber)")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                }

                                                if remainingCount > 0 {
                                                    Text("+\(remainingCount) more")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .padding(.horizontal, 12)
                                    }
                                }
                                .padding(.horizontal)
                                .id(message.id)
                            }

                            // If we're waiting for an answer, show a visible placeholder bubble.
                            if isLoading {
                                HStack {
                                    MultilineText("…")
                                        .padding(12)
                                        .background(Color.gray.opacity(0.1))
                                        .cornerRadius(16)
                                        .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
                                    Spacer()
                                }
                                .padding(.horizontal)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                        .padding(.vertical)
                    }
                    .onChange(of: chatMessages.last?.text) {
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: isLoading) {
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }

            Divider()

            if let context = selectedContext {
                HStack {
                    Text("📎 Context: \"\(context.prefix(50))…\"")
                        .font(.footnote)
                        .padding(8)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)

                    Button(action: { selectedContext = nil }) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            
            HStack(spacing: 10) {
                ZStack(alignment: .trailing) {
                    TextField("Type your question…", text: $newMessage)
                        .onSubmit {
                            sendMessage()
                        }
                        .textFieldStyle(PlainTextFieldStyle())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .font(.body)
                        .frame(height: 50)

                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                            .padding(.trailing, 40)
                    }
                }

                Button(isLoading ? "Stop" : "Send") {
                    if isLoading {
                        stopMessage()
                    } else {
                        sendMessage()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!isLoading && newMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    
}
