import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct PDFKitView: NSViewRepresentable {
    @Binding var url: URL?
    
    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        context.coordinator.pdfView = pdfView
        return pdfView
    }
    
    
    func updateNSView(_ nsView: PDFView, context: Context) {
        if let url = url {
            nsView.document = PDFDocument(url: url)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var pdfView: PDFView?
    }
}


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
    @State private var docTitle: String = ""
    @State private var currentPage: Int = 0
    @State private var totalPages: Int = 0
    @State private var isChatVisible: Bool = true
    @State private var isLoadingResponse: Bool = false
    @State private var ollamaModel: String = ConfigManager.shared.ollamaChatModel
    @State private var isKeyFieldVisible: Bool = false
    @State private var surroundingPages: String = ""
    @State private var selectedText: String? = nil
    @State private var useRAG: Bool = ConfigManager.shared.useRAG
    @State private var searchQuery: String = ""
    @State private var showSearchBar: Bool = false
    @State private var showSearchResults: Bool = false
    @State private var pdfSearchResults: [PDFSelection] = []
    @State private var currentSearchIndex: Int = 0

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
                            VStack(spacing: 0) {
                                // Search bar
                                if showSearchBar {
                                    HStack(spacing: 8) {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundColor(.secondary)
                                        TextField("Search in PDF...", text: $searchQuery)
                                            .textFieldStyle(PlainTextFieldStyle())
                                            .onSubmit {
                                                performPDFSearch()
                                            }
                                            .onChange(of: searchQuery) { _, newValue in
                                                if newValue.isEmpty {
                                                    clearPDFSearch()
                                                } else {
                                                    // Perform search as user types
                                                    performPDFSearch()
                                                }
                                            }
                                        if !searchQuery.isEmpty {
                                            // Results counter (show even if no results)
                                            if pdfSearchResults.isEmpty {
                                                Text("No matches")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            } else {
                                                Text("\(currentSearchIndex + 1) of \(pdfSearchResults.count)")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .frame(minWidth: 60)
                                            }

                                            // Previous result button
                                            Button(action: { navigateToPreviousSearchResult() }) {
                                                Image(systemName: "chevron.up")
                                                    .foregroundColor(pdfSearchResults.isEmpty ? .gray : .accentColor)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(pdfSearchResults.isEmpty)
                                            .help("Previous match")

                                            // Next result button
                                            Button(action: { navigateToNextSearchResult() }) {
                                                Image(systemName: "chevron.down")
                                                    .foregroundColor(pdfSearchResults.isEmpty ? .gray : .accentColor)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(pdfSearchResults.isEmpty)
                                            .help("Next match")

                                            // Toggle search results list
                                            if !pdfSearchResults.isEmpty {
                                                Button(action: {
                                                    withAnimation {
                                                        showSearchResults.toggle()
                                                    }
                                                }) {
                                                    Image(systemName: showSearchResults ? "sidebar.left" : "list.bullet")
                                                        .foregroundColor(.accentColor)
                                                }
                                                .buttonStyle(.plain)
                                                .help("Show all matches")
                                            }

                                            // Clear button
                                            Button(action: {
                                                searchQuery = ""
                                                clearPDFSearch()
                                            }) {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Clear search")
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .overlay(
                                        Rectangle()
                                            .frame(height: 1)
                                            .foregroundColor(Color.gray.opacity(0.3)),
                                        alignment: .bottom
                                    )
                                }

                                HStack(spacing: 0) {
                                    // Search results sidebar
                                    if showSearchResults && !pdfSearchResults.isEmpty {
                                        VStack(spacing: 0) {
                                            HStack {
                                                Text("\(pdfSearchResults.count) matches")
                                                    .font(.headline)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 6)
                                                Spacer()
                                            }
                                            .background(Color(NSColor.controlBackgroundColor))

                                            Divider()

                                            ScrollView {
                                                LazyVStack(spacing: 0) {
                                                    ForEach(Array(pdfSearchResults.enumerated()), id: \.offset) { index, selection in
                                                        SearchResultRow(
                                                            selection: selection,
                                                            index: index,
                                                            searchQuery: searchQuery,
                                                            isSelected: index == currentSearchIndex,
                                                            onTap: {
                                                                currentSearchIndex = index
                                                                highlightCurrentSearchResult()
                                                            }
                                                        )
                                                        Divider()
                                                    }
                                                }
                                            }
                                        }
                                        .frame(width: 250)
                                        .background(Color(NSColor.controlBackgroundColor))

                                        Divider()
                                    }

                                    PDFContainerView(url: $pdfUrl, pdfView: $pdfView)
                                }
                            }
                            .frame(width: geometry.size.width - (isChatVisible ? chatWidth : 0))
                            .layoutPriority(1)

                            if isChatVisible {
                                Divider()
                                    .background(Color.gray.opacity(0.5))
                                    .frame(width: 4)
                                    .gesture(
                                        DragGesture(minimumDistance: 10)
                                            .onChanged { value in
                                                DispatchQueue.main.async {
                                                    let newWidth = chatWidth - value.translation.width
                                                    chatWidth = min(max(newWidth, 200), geometry.size.width * 0.7)
                                                }
                                            }
                                    )
                                    .onHover {
                                        hovering in
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
                                    .transition(.move(edge: .trailing))
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            NSApp.windows.first?.title = "punugu+chutney"
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willBecomeActiveNotification)) { _ in
            addMenuShortcut()
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
        .onAppear {
            setupKeyboardShortcuts()
        }
    }

    private func setupKeyboardShortcuts() {
        // Add global keyboard shortcuts for search navigation
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Cmd+G: Next search result
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "g" {
                if event.modifierFlags.contains(.shift) {
                    // Cmd+Shift+G: Previous search result
                    if showSearchBar && !pdfSearchResults.isEmpty {
                        navigateToPreviousSearchResult()
                        return nil
                    }
                } else {
                    // Cmd+G: Next search result
                    if showSearchBar && !pdfSearchResults.isEmpty {
                        navigateToNextSearchResult()
                        return nil
                    }
                }
            }

            // Debug: Cmd+Shift+T to test Ollama connectivity/model
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift),
               event.charactersIgnoringModifiers == "t" {
                chatService.testOllamaChat { result in
                    switch result {
                    case .success(let content):
                        print("Ollama chat test response: \(content)")
                    case .failure(let error):
                        print("Ollama chat test failed: \(error)")
                    }
                }
                return nil
            }

            return event
        }
    }
    
    private var headerBar: some View {
        HStack(alignment: .center) {
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
            Spacer()
            if pdfUrl != nil {
                Button(action: {
                    withAnimation {
                        showSearchBar.toggle()
                    }
                }) {
                    Image(systemName: "magnifyingglass")
                        .imageScale(.large)
                        .foregroundColor(showSearchBar ? .accentColor : .secondary)
                        .padding(.trailing, 4)
                }
                .buttonStyle(.plain)
                .onHover {
                    hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Find in PDF (⌘F)")

                Button(action: {
                    withAnimation {
                        isKeyFieldVisible.toggle()
                    }
                }) {
                    Image(systemName: "key")
                        .imageScale(.large)
                        .foregroundColor(.accentColor)
                        .padding(.trailing, 4)
                }
                .popover(isPresented: $isKeyFieldVisible) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("AI Configuration")
                            .font(.headline)

                        Text("Chat Model")
                            .font(.subheadline)
                        TextField("ministral-3:3b", text: $ollamaModel)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 300)
                        Text("Model for answering questions")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        Toggle("Enable Context Search for Questions", isOn: $useRAG)
                            .font(.subheadline)

                        Text("When enabled, searches entire PDF for relevant context")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        Text("Make sure Ollama is running on port 11434")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button("Save") {
                            ConfigManager.shared.saveOllamaChatModel(ollamaModel)
                            ConfigManager.shared.saveUseRAG(useRAG)

                            isKeyFieldVisible = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding()
                    .frame(width: 340)
                }
                .buttonStyle(.plain)
                .onHover {
                    hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                
                
                Button(action: {
                    withAnimation {
                        isChatVisible.toggle()
                    }
                }) {
                    Image(systemName: isChatVisible ? "sidebar.trailing" : "sidebar.leading")
                        .imageScale(.large)
                        .foregroundColor(.accentColor)
                        .padding(.trailing, 4)
                }
                .buttonStyle(.plain)
                .onHover {
                    hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color(NSColor.windowBackgroundColor))
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

    private func addMenuShortcut() {
        guard let mainMenu = NSApp.mainMenu,
              let fileMenu = mainMenu.item(withTitle: "File")?.submenu,
              fileMenu.item(withTitle: "Open") == nil,
              let appDelegate = NSApp.delegate as? AppDelegate else {
            return
        }

        let openItem = NSMenuItem(title: "Open", action: #selector(AppDelegate.openDocument), keyEquivalent: "o")
        openItem.target = appDelegate
        fileMenu.addItem(openItem)
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

        // Wait for PDFView to actually load the document before we index it.
        // Retry a few times with a short delay to avoid races with SwiftUI's updateNSView.
        var attempts = 0
        func tryIndexPDF() {
            let delay = 0.1 * Double(attempts) // 0.0, 0.1, 0.2, ... seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let pdfDoc = pdfView?.document {
                    print("✅ PDF document loaded (attempt \(attempts + 1), pages: \(pdfDoc.pageCount))")
                    updatePageInfo()
                    extractSurroundingPagesText()

                    // Index PDF for text search (this will set pdfDocument in TextSearchService)
                    searchService.indexPDF(document: pdfDoc)
                } else if attempts < 10 {
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

            if useRAG {
                let result = await searchService.getContextForQuery(trimmed)
                contextToUse = result.context
                pages = result.pages
            } else if selectedText?.isEmpty == false {
                contextToUse = selectedText
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
    
    private func performPDFSearch() {
        guard !searchQuery.isEmpty, let pdfView = pdfView, let document = pdfView.document else {
            clearPDFSearch()
            return
        }

        // Clear previous search
        pdfSearchResults.removeAll()
        currentSearchIndex = 0

        // Search all pages using PDFKit with case-insensitive option
        let selections = document.findString(searchQuery, withOptions: .caseInsensitive)
        pdfSearchResults = selections

        print("🔍 PDFKit search found \(selections.count) matches for '\(searchQuery)'")

        if !selections.isEmpty {
            currentSearchIndex = 0
            highlightCurrentSearchResult()
        } else {
            // Clear any previous highlights
            pdfView.clearSelection()
        }
    }

    private func navigateToNextSearchResult() {
        guard !pdfSearchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex + 1) % pdfSearchResults.count
        highlightCurrentSearchResult()
    }

    private func navigateToPreviousSearchResult() {
        guard !pdfSearchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex - 1 + pdfSearchResults.count) % pdfSearchResults.count
        highlightCurrentSearchResult()
    }

    private func highlightCurrentSearchResult() {
        guard !pdfSearchResults.isEmpty,
              currentSearchIndex >= 0,
              currentSearchIndex < pdfSearchResults.count,
              let pdfView = pdfView else { return }

        let selection = pdfSearchResults[currentSearchIndex]

        // Set the current selection to highlight it
        pdfView.setCurrentSelection(selection, animate: true)

        // Scroll to make the selection visible in the center if possible
        pdfView.scrollSelectionToVisible(nil)

        // Get page of current selection and navigate to it
        if let page = selection.pages.first {
            pdfView.go(to: page)
        }

        print("📍 Highlighting match \(currentSearchIndex + 1)/\(pdfSearchResults.count)")
    }

    private func clearPDFSearch() {
        pdfSearchResults.removeAll()
        currentSearchIndex = 0
        showSearchResults = false
        pdfView?.clearSelection()
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

// Search result row component
struct SearchResultRow: View {
    let selection: PDFSelection
    let index: Int
    let searchQuery: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Page \(pageNumber)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("#\(index + 1)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text(contextText)
                    .font(.system(.caption, design: .default))
                    .lineLimit(3)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pageNumber: Int {
        guard let page = selection.pages.first,
              let document = page.document else {
            return 0
        }
        return document.index(for: page) + 1
    }

    private var contextText: String {
        let fullText = selection.string ?? ""

        // Get more context around the match
        if let page = selection.pages.first,
           let pageText = page.string,
           let range = pageText.range(of: fullText) {

            // Get context before
            let contextBefore = 40
            let startIndex = pageText.index(range.lowerBound, offsetBy: -contextBefore, limitedBy: pageText.startIndex) ?? pageText.startIndex

            // Get context after
            let contextAfter = 80
            let endIndex = pageText.index(range.upperBound, offsetBy: contextAfter, limitedBy: pageText.endIndex) ?? pageText.endIndex

            var context = String(pageText[startIndex..<endIndex])

            // Clean up whitespace
            context = context.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            context = context.trimmingCharacters(in: .whitespacesAndNewlines)

            // Add ellipsis if truncated
            if startIndex != pageText.startIndex {
                context = "..." + context
            }
            if endIndex != pageText.endIndex {
                context = context + "..."
            }

            return context
        }

        return fullText
    }
}

#Preview {
    ContentView()
}
