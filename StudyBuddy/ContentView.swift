import SwiftUI
import PDFKit
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    @objc func openDocument() {
        NotificationCenter.default.post(name: NSNotification.Name("ManualOpenPDF"), object: nil)
    }
    
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        NotificationCenter.default.post(name: NSNotification.Name("ManualOpenPDF"), object: url)
        return true
    }
}

struct PDFKitViewWithReference: NSViewRepresentable {
    @Binding var url: URL?
    @Binding var pdfView: PDFView?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical

        // Enable selection and better search visualization
        view.backgroundColor = NSColor.controlBackgroundColor

        // Configure for better search highlighting
        view.highlightedSelections = []

        DispatchQueue.main.async {
            self.pdfView = view
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if let url = url {
            nsView.document = PDFDocument(url: url)
        } else {
            nsView.document = nil
        }
    }
}

struct ContentView: View {
    @State private var chatMessages: [ChatMessage] = []
    @State private var newMessage: String = ""
    @State private var pdfUrl: URL? = nil
    @State private var pdfView: PDFView? = nil
    @State private var chatWidth: CGFloat = ConfigManager.shared.defaultChatWidth

    // PDFKit search UI state
    @State private var searchQuery: String = ""
    @State private var searchResults: [PDFSearchResult] = []
    @State private var isSearchVisible: Bool = true
    @State private var selectedSearchResultID: UUID? = nil
    @State private var searchSidebarWidth: CGFloat = 260

    @State private var docTitle: String = ""
    @State private var currentPage: Int = 0
    @State private var totalPages: Int = 0
    @State private var isLoadingResponse: Bool = false
    @State private var ollamaModel: String = ConfigManager.shared.ollamaChatModel
    @State private var isSettingsVisible: Bool = false
    @State private var surroundingPages: String = ""
    @State private var selectedText: String? = nil
    @State private var useRAG: Bool = ConfigManager.shared.useRAG

    @StateObject private var chatService = ChatService()
    @StateObject private var searchService = TextSearchService()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ZStack {
                if pdfUrl == nil {
                    VStack {
                        Spacer()
                        Button("Open PDF", action: openPDF)
                            .controlSize(.large)
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                } else {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            // Left search sidebar
                            if isSearchVisible {
                                searchSidebar
                                    .frame(width: min(searchSidebarWidth, max(200, geometry.size.width * 0.45)))

                                Divider()
                                    .frame(width: 1)
                            }

                            VStack(spacing: 0) {
                                PDFContainerView(url: $pdfUrl, pdfView: $pdfView)
                            }
                            .frame(width: geometry.size.width - (isSearchVisible ? searchSidebarWidth : 0) - chatWidth)
                            .layoutPriority(1)

                            Divider()
                                .background(Color.gray.opacity(0.5))
                                .frame(width: 4)
                                .gesture(
                                    DragGesture(minimumDistance: 10)
                                        .onChanged { value in
                                            DispatchQueue.main.async {
                                                let newWidth = chatWidth - value.translation.width
                                                chatWidth = min(
                                                    max(newWidth, ConfigManager.shared.minChatWidth),
                                                    geometry.size.width * ConfigManager.shared.maxChatWidthFraction
                                                )
                                            }
                                        }
                                )
                                .onHover { hovering in
                                    if hovering {
                                        NSCursor.resizeLeftRight.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                                .padding(.vertical, 8)
                                .background(Color.gray.opacity(0.1))

                            ChatPanel(
                                chatMessages: $chatMessages,
                                newMessage: $newMessage,
                                isLoading: $isLoadingResponse,
                                selectedContext: $selectedText,
                                ollamaModel: $ollamaModel,
                                useRAG: $useRAG,
                                searchService: searchService,
                                sendMessage: sendMessage,
                                stopMessage: stopChat
                            )
                            .frame(width: chatWidth)
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.PDFViewPageChanged, object: pdfView)) { _ in
            updatePageInfo()
            extractSurroundingPagesText()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ManualOpenPDF"))) { notification in
            if let url = notification.object as? URL {
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                pdfUrl = url
                setDocumentMeta(from: url)
            } else {
                openPDF()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.PDFViewSelectionChanged, object: pdfView)) { _ in
            selectedText = pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let item = providers.first else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url, url.pathExtension.lowercased() == "pdf" else { return }
                DispatchQueue.main.async {
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    pdfUrl = url
                    setDocumentMeta(from: url)
                }
            }
            return true
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(docTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                if totalPages > 0 {
                    Text("\(currentPage) / \(totalPages)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if pdfUrl != nil {
                HStack(spacing: 8) {
                    TextField("Search in PDF", text: $searchQuery)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(minWidth: 220, idealWidth: 280)
                        .onSubmit {
                            performPDFKitSearch()
                        }

                    Button("Search") {
                        performPDFKitSearch()
                    }
                    .buttonStyle(.bordered)
                    .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(action: {
                        isSearchVisible.toggle()
                    }) {
                        Image(systemName: "sidebar.leading")
                            .imageScale(.medium)
                    }
                    .buttonStyle(.plain)
                    .help(isSearchVisible ? "Hide search results" : "Show search results")

                    Button(action: {
                        isSettingsVisible.toggle()
                    }) {
                        Image(systemName: "gearshape")
                            .imageScale(.large)
                            .foregroundColor(.accentColor)
                            .padding(.trailing, 4)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isSettingsVisible) {
                        SettingsPopover(
                            ollamaModel: $ollamaModel,
                            useRAG: $useRAG
                        )
                    }
                    .help("Settings")
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var searchSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Search Results")
                    .font(.headline)
                Spacer()
                if !searchResults.isEmpty {
                    Text("\(searchResults.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No results")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Search uses PDFKit and matches are highlighted in the document.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                Spacer()
            } else {
                List(selection: $selectedSearchResultID) {
                    ForEach(searchResults) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Page \(result.pageNumber)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text(result.snippet)
                                .font(.callout)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 4)
                        .tag(result.id)
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selectedSearchResultID) {
                    guard let id = selectedSearchResultID,
                          let result = searchResults.first(where: { $0.id == id }) else { return }
                    goToSearchResult(result)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func performPDFKitSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearPDFKitSearch()
            return
        }
        guard let pdfView, let doc = pdfView.document else {
            clearPDFKitSearch()
            return
        }

        let selections = doc.findString(query, withOptions: .caseInsensitive)
        let results: [PDFSearchResult] = selections.compactMap { sel in
            guard let page = sel.pages.first else { return nil }
            let pageNumber = doc.index(for: page) + 1

            // Build a small snippet. PDFSelection.string often contains the match; fall back gracefully.
            let raw = (sel.string ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = raw.isEmpty ? query : raw

            return PDFSearchResult(pageNumber: pageNumber, selection: sel, snippet: snippet)
        }

        searchResults = results
        selectedSearchResultID = results.first?.id

        // Highlight first result automatically.
        if let first = results.first {
            goToSearchResult(first)
        } else {
            pdfView.clearSelection()
        }
    }

    private func clearPDFKitSearch() {
        searchResults.removeAll()
        selectedSearchResultID = nil
        pdfView?.clearSelection()
    }

    private func goToSearchResult(_ result: PDFSearchResult) {
        guard let pdfView else { return }

        // Navigate + highlight using PDFKit.
        pdfView.setCurrentSelection(result.selection, animate: true)
        pdfView.scrollSelectionToVisible(nil)

        if let page = result.selection.pages.first {
            pdfView.go(to: page)
        }
    }

    private func openPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let selectedURL = panel.url {
            NSDocumentController.shared.noteNewRecentDocumentURL(selectedURL)
            pdfUrl = selectedURL
            setDocumentMeta(from: selectedURL)
        }
    }

    private func updatePageInfo() {
        guard let pdfView = pdfView, let doc = pdfView.document else { return }
        if let page = pdfView.currentPage {
            currentPage = doc.index(for: page) + 1
        }
        totalPages = doc.pageCount
    }

    private func setDocumentMeta(from url: URL) {
        docTitle = url.lastPathComponent
        print("📄 Loading PDF: \(url.lastPathComponent)")

        // Clear search state on new document
        searchQuery = ""
        clearPDFKitSearch()

        var attempts = 0
        func tryIndexPDF() {
            let delay = ConfigManager.shared.pdfIndexRetryBaseDelaySeconds * Double(attempts)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let pdfDoc = pdfView?.document {
                    print("✅ PDF document loaded (attempt \(attempts + 1), pages: \(pdfDoc.pageCount))")
                    updatePageInfo()
                    extractSurroundingPagesText()
                    searchService.indexPDF(document: pdfDoc)
                } else if attempts < ConfigManager.shared.pdfIndexMaxAttempts {
                    attempts += 1
                    print("⏳ Waiting for PDF to load… (attempt \(attempts))")
                    tryIndexPDF()
                } else {
                    print("⚠️ Failed to load PDF document for indexing after \(attempts) attempts")
                }
            }
        }

        tryIndexPDF()
    }
    
    private func sendMessage() {
        let trimmed = newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Capture current input and clear immediately for snappy UI.
        newMessage = ""

        // Insert placeholder right away so the UI responds instantly.
        let placeholderID = UUID()
        isLoadingResponse = true

        // Add the user message now (context will be filled in once computed).
        let userMessageID = UUID()
        chatMessages.append(ChatMessage(id: userMessageID, text: trimmed, isUser: true, context: nil, references: []))
        chatMessages.append(ChatMessage(id: placeholderID, text: "…", isUser: false))

        print("🗣️ User asked: \(trimmed)")

        Task {
            var contextToUse: String?
            var pages: [Int] = []

            // If the user explicitly highlighted text, use it as the context directly.
            // Important: do NOT run the PDF text search/RAG pipeline in that case.
            if let selection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty {
                contextToUse = selection
                pages = []
            } else if useRAG {
                let result = await searchService.getContextForQuery(trimmed)
                contextToUse = result.context
                pages = result.pages
            } else {
                contextToUse = surroundingPages
            }

            await MainActor.run {
                print("🧾 Context chars: \(contextToUse?.count ?? 0), pages: \(pages)")

                // Update the user message with the context we ended up using.
                if let idx = chatMessages.firstIndex(where: { $0.id == userMessageID }) {
                    chatMessages[idx].context = contextToUse
                    chatMessages[idx].references = pages.map { PDFReference(pageNumber: $0, text: "", relevanceScore: 1.0) }
                }

                // Start streaming using the updated messages (exclude the assistant placeholder).
                var didReceiveAnyChunk = false

                chatService.sendMessageStream(
                    messages: Array(chatMessages.dropLast()),
                    apiKey: "",
                    onChunk: { chunk in
                        didReceiveAnyChunk = true
                        if let index = chatMessages.firstIndex(where: { $0.id == placeholderID }) {
                            if chatMessages[index].text == "…" {
                                chatMessages[index].text = ""
                            }
                            chatMessages[index].text += chunk
                        }
                    },
                    onComplete: {
                        isLoadingResponse = false

                        // If streaming produced nothing, try a single non-stream request before giving up.
                        if !didReceiveAnyChunk {
                            let history = Array(chatMessages.dropLast())
                            chatService.sendMessageOnce(messages: history) { result in
                                switch result {
                                case .success(let full):
                                    if let index = chatMessages.firstIndex(where: { $0.id == placeholderID }) {
                                        chatMessages[index].text = full.isEmpty ? "(Empty response)" : full
                                    }
                                case .failure(let error):
                                    if let index = chatMessages.firstIndex(where: { $0.id == placeholderID }) {
                                        chatMessages[index].text = "No response received. Error: \(error.localizedDescription)"
                                    }
                                }
                            }
                        }

                        print("✅ Stream complete (receivedChunks=\(didReceiveAnyChunk))")
                    },
                    onError: { msg in
                        // Show the error directly in-chat so it's obvious what failed.
                        if let index = chatMessages.firstIndex(where: { $0.id == placeholderID }) {
                            chatMessages[index].text = "⚠️ \(msg)"
                        }
                    }
                )
            }
        }
    }
    
    private func extractSurroundingPagesText() {
        guard let pdfView = pdfView, let document = pdfView.document else {
            return
        }

        guard let current = pdfView.currentPage else { return }

        let currentIndex = document.index(for: current)
        let total = document.pageCount

        let indicesToExtract = [
            currentIndex - 1,
            currentIndex,
            currentIndex + 1
        ].filter { $0 >= 0 && $0 < total }

        var text = ""

        for i in indicesToExtract {
            if let pageText = document.page(at: i)?.string {
                text += "[Page \(i + 1)]\n" + pageText + "\n\n"
            }
        }

        surroundingPages = text
    }

    private func stopChat() {
        chatService.cancelStreaming()
        isLoadingResponse = false
    }
}

private struct SettingsPopover: View {
    @Binding var ollamaModel: String
    @Binding var useRAG: Bool

    @State private var ollamaBaseURL: String = ConfigManager.shared.ollamaBaseURL
    @State private var chatTimeoutSeconds: String = String(Int(ConfigManager.shared.chatTimeout))
    @State private var fastMode: Bool = ConfigManager.shared.fastMode
    @State private var maxHistory: String = String(ConfigManager.shared.maxChatHistoryMessages)

    @State private var maxPagesDisplay: String = String(ConfigManager.shared.maxPagesDisplay)
    @State private var includePageContext: Bool = ConfigManager.shared.includePageContext
    @State private var maxRAGContextChars: String = String(ConfigManager.shared.maxRAGContextChars)
    @State private var minRelevantSnippets: String = String(ConfigManager.shared.minRelevantSnippetsBeforeStop)

    @State private var minChatWidth: String = String(Int(ConfigManager.shared.minChatWidth))
    @State private var maxChatWidthFraction: String = String(format: "%.2f", Double(ConfigManager.shared.maxChatWidthFraction))
    @State private var chatBubbleMaxWidth: String = String(Int(ConfigManager.shared.chatBubbleMaxWidth))
    @State private var settingsPopoverWidth: String = String(Int(ConfigManager.shared.settingsPopoverWidth))

    @State private var pdfIndexMaxAttempts: String = String(ConfigManager.shared.pdfIndexMaxAttempts)
    @State private var pdfIndexRetryBaseDelaySeconds: String = String(format: "%.2f", ConfigManager.shared.pdfIndexRetryBaseDelaySeconds)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)

            Group {
                Text("Ollama")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("Base URL", text: $ollamaBaseURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                TextField("Chat Model", text: $ollamaModel)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                HStack {
                    Text("Timeout (s)")
                    Spacer()
                    TextField("20", text: $chatTimeoutSeconds)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 90)
                }
            }

            Divider()

            Group {
                Toggle("Enable Context Search (RAG)", isOn: $useRAG)
                    .font(.subheadline)

                Toggle("Fast Mode (lower latency)", isOn: $fastMode)
                    .font(.subheadline)

                HStack {
                    Text("Chat history messages")
                    Spacer()
                    TextField("6", text: $maxHistory)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 90)
                }
            }

            Divider()

            Group {
                Text("RAG")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Max pages")
                    Spacer()
                    TextField("100", text: $maxPagesDisplay)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 90)
                }

                Toggle("Include full page text in context", isOn: $includePageContext)

                HStack {
                    Text("Max context chars")
                    Spacer()
                    TextField("300", text: $maxRAGContextChars)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 90)
                }

                HStack {
                    Text("Min relevant snippets")
                    Spacer()
                    TextField("5", text: $minRelevantSnippets)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 90)
                }
            }

            Divider()

            Group {
                Text("UI")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Min chat width")
                    Spacer()
                    TextField("240", text: $minChatWidth)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 90)
                }

                HStack {
                    Text("Max chat width fraction")
                    Spacer()
                    TextField("0.70", text: $maxChatWidthFraction)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 90)
                }

                HStack {
                    Text("Bubble max width")
                    Spacer()
                    TextField("300", text: $chatBubbleMaxWidth)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 90)
                }

                HStack {
                    Text("Settings width")
                    Spacer()
                    TextField("360", text: $settingsPopoverWidth)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 90)
                }
            }

            Divider()

            Group {
                Text("PDF Indexing")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Max attempts")
                    Spacer()
                    TextField("10", text: $pdfIndexMaxAttempts)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 90)
                }

                HStack {
                    Text("Retry base delay (s)")
                    Spacer()
                    TextField("0.10", text: $pdfIndexRetryBaseDelaySeconds)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 90)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Save") {
                    ConfigManager.shared.saveOllamaBaseURL(ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                    ConfigManager.shared.saveOllamaChatModel(ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines))
                    ConfigManager.shared.saveUseRAG(useRAG)
                    ConfigManager.shared.saveFastMode(fastMode)

                    if let t = Double(chatTimeoutSeconds) {
                        ConfigManager.shared.saveChatTimeout(t)
                    }
                    if let h = Int(maxHistory) {
                        ConfigManager.shared.saveMaxChatHistoryMessages(h)
                    }

                    if let v = Int(maxPagesDisplay) {
                        ConfigManager.shared.saveMaxPagesDisplay(v)
                    }
                    ConfigManager.shared.saveIncludePageContext(includePageContext)
                    if let v = Int(maxRAGContextChars) {
                        ConfigManager.shared.saveMaxRAGContextChars(v)
                    }
                    if let v = Int(minRelevantSnippets) {
                        ConfigManager.shared.saveMinRelevantSnippetsBeforeStop(v)
                    }

                    if let v = Double(minChatWidth) {
                        ConfigManager.shared.saveMinChatWidth(v)
                    }
                    if let v = Double(maxChatWidthFraction) {
                        ConfigManager.shared.saveMaxChatWidthFraction(v)
                    }
                    if let v = Double(chatBubbleMaxWidth) {
                        ConfigManager.shared.saveChatBubbleMaxWidth(v)
                    }
                    if let v = Double(settingsPopoverWidth) {
                        ConfigManager.shared.saveSettingsPopoverWidth(v)
                    }

                    if let v = Int(pdfIndexMaxAttempts) {
                        ConfigManager.shared.savePDFIndexMaxAttempts(v)
                    }
                    if let v = Double(pdfIndexRetryBaseDelaySeconds) {
                        ConfigManager.shared.savePDFIndexRetryBaseDelaySeconds(v)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: ConfigManager.shared.settingsPopoverWidth)
    }
}

#Preview {
    ContentView()
}
