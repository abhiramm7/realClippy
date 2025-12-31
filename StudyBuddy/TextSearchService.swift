import Foundation
import PDFKit
import Combine

struct SearchResult: Identifiable {
    var id = UUID()
    var pageNumber: Int
    var matchText: String
    var context: String
    var matchRange: NSRange
}

class TextSearchService: ObservableObject {
    @Published var searchResults: [SearchResult] = []
    @Published var isSearching: Bool = false
    @Published var currentSearchQuery: String = ""

    private var pdfDocument: PDFDocument? // Reference to the PDF document
    private var pdfPages: [Int: String] = [:] // Page number: Full text (for context extraction)

    // Simple in-memory cache for keyword extraction per query
    private var keywordCache: [String: [String]] = [:]

    // Cache for final context per question (avoids repeating the whole RAG pipeline when the user re-asks)
    private var contextCache: [String: (context: String, pages: [Int], timestamp: Date)] = [:]

    // Caches accessed from parallel tasks must be concurrency-safe.
    private actor RelevanceDecisionCache {
        private var storage: [String: Bool] = [:]
        func get(_ key: String) -> Bool? { storage[key] }
        func set(_ key: String, value: Bool) { storage[key] = value }
        func clear() { storage.removeAll() }
    }

    private let relevanceDecisionCache = RelevanceDecisionCache()

    /// Lightweight snapshot of relevant configuration values.
    private struct LocalConfig {
        let searchContextLines: Int
        let searchCaseSensitive: Bool
        let searchWholeWords: Bool
        let maxPagesDisplay: Int
        let includePageContext: Bool
        let maxRAGContextChars: Int
        let minRelevantSnippetsBeforeStop: Int
        let ollamaBaseURL: String
        let ollamaChatModel: String
        let chatOptions: [String: Any]
        let keywordOptions: [String: Any]
        let relevanceOptions: [String: Any]
        let fastMode: Bool
    }

    /// Lazily materialized local config snapshot from ConfigManager.shared.
    private var config: LocalConfig {
        let manager = ConfigManager.shared
        return LocalConfig(
            searchContextLines: manager.searchContextLines,
            searchCaseSensitive: manager.searchCaseSensitive,
            searchWholeWords: manager.searchWholeWords,
            maxPagesDisplay: manager.maxPagesDisplay,
            includePageContext: manager.includePageContext,
            maxRAGContextChars: manager.maxRAGContextChars,
            minRelevantSnippetsBeforeStop: manager.minRelevantSnippetsBeforeStop,
            ollamaBaseURL: manager.ollamaBaseURL,
            ollamaChatModel: manager.ollamaChatModel,
            chatOptions: manager.ollamaOptionsDictionary(for: .chat),
            keywordOptions: manager.ollamaOptionsDictionary(for: .keywords),
            relevanceOptions: manager.ollamaOptionsDictionary(for: .relevance),
            fastMode: manager.fastMode
        )
    }

    func indexPDF(document: PDFDocument) {
        // Store the document reference immediately for PDFKit native search
        // This must happen synchronously so search can work right away
        self.pdfDocument = document
        print("PDF document reference stored for native search")

        // Index text asynchronously for context extraction
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var pages: [Int: String] = [:]

            for pageIndex in 0..<document.pageCount {
                if let page = document.page(at: pageIndex),
                   let pageText = page.string {
                    pages[pageIndex + 1] = pageText
                }
            }

            DispatchQueue.main.async {
                self.pdfPages = pages
                print("Indexed \(pages.count) pages for text search (PDFKit native search enabled)")
            }
        }
    }

    /// Search for a single keyword using PDFKit's native search
    func search(query: String, caseSensitive: Bool = false, wholeWords: Bool = false) -> [SearchResult] {
        guard !query.isEmpty else {
            print("Search query is empty")
            return []
        }

        guard let document = pdfDocument else {
            print("PDF document not loaded")
            return []
        }

        print("Searching '\(query)' using PDFKit native search")

        var searchOptions: NSString.CompareOptions = []
        if !caseSensitive {
            searchOptions.insert(.caseInsensitive)
            searchOptions.insert(.diacriticInsensitive)
        }

        let selections = document.findString(query, withOptions: searchOptions)
        print("PDFKit found \(selections.count) selections for '\(query)'")

        var results: [SearchResult] = []
        let contextLines = config.searchContextLines

        for selection in selections {
            guard let page = selection.pages.first else { continue }

            let pageIndex = document.index(for: page)
            let pageNumber = pageIndex + 1
            let matchText = selection.string ?? query

            // Get the page text for context
            let pageText = pdfPages[pageNumber] ?? page.string ?? ""

            // Get context around the match
            let context = getContextForSelection(selection, pageText: pageText, lines: contextLines)

            // Convert to NSRange (approximate for the match)
            let nsRange = NSRange(location: 0, length: matchText.count)

            let result = SearchResult(
                pageNumber: pageNumber,
                matchText: matchText,
                context: context,
                matchRange: nsRange
            )

            if wholeWords {
                let isWholeWord = isWholeWordInContext(matchText: matchText, context: pageText)
                if !isWholeWord {
                    print("  Skipping partial word match on page \(pageNumber)")
                    continue
                }
            }

            results.append(result)
            print("  Match found on page \(pageNumber): '\(matchText)'")
        }

        print("===== FINAL: Found \(results.count) matches for '\(query)' =====")
        return results
    }

    /// Get context around a PDFSelection
    private func getContextForSelection(_ selection: PDFSelection, pageText: String, lines: Int) -> String {
        // If we have the matched text, try to find it in the page text and get context
        guard let matchedText = selection.string, !pageText.isEmpty else {
            return selection.string ?? ""
        }

        // Try to find the match in the page text
        if let range = pageText.range(of: matchedText, options: .caseInsensitive) {
            return getContext(for: range, in: pageText, lines: lines)
        }

        // Fallback: return just the matched text
        return matchedText
    }

    /// Check if a match is a whole word in context
    private func isWholeWordInContext(matchText: String, context: String) -> Bool {
        // Search for the match text in context and check word boundaries
        guard let range = context.range(of: matchText, options: .caseInsensitive) else {
            return true // Can't verify, assume it's valid
        }
        return isWholeWordMatch(range: range, in: context)
    }

    /// Check if a match is a whole word (bounded by word boundaries)
    private func isWholeWordMatch(range: Range<String.Index>, in text: String) -> Bool {
        let characterSet = CharacterSet.alphanumerics

        // Check character before match
        if range.lowerBound > text.startIndex {
            let beforeIndex = text.index(before: range.lowerBound)
            let beforeChar = text[beforeIndex]
            if let scalar = beforeChar.unicodeScalars.first, characterSet.contains(scalar) {
                return false // Previous character is alphanumeric, not a word boundary
            }
        }

        // Check character after match
        if range.upperBound < text.endIndex {
            let afterChar = text[range.upperBound]
            if let scalar = afterChar.unicodeScalars.first, characterSet.contains(scalar) {
                return false // Next character is alphanumeric, not a word boundary
            }
        }

        return true // Both boundaries are valid
    }

    private func getContext(for range: Range<String.Index>, in text: String, lines: Int) -> String {

        // Find start of context (go back 'lines' newlines or to start)
        var contextStart = text.startIndex
        var newlineCount = 0
        var currentIndex = range.lowerBound

        while currentIndex > text.startIndex && newlineCount < lines {
            currentIndex = text.index(before: currentIndex)
            if text[currentIndex] == "\n" {
                newlineCount += 1
            }
            if newlineCount < lines {
                contextStart = currentIndex
            }
        }

        // Find end of context (go forward 'lines' newlines or to end)
        var contextEnd = text.endIndex
        newlineCount = 0
        currentIndex = range.upperBound

        while currentIndex < text.endIndex && newlineCount < lines {
            if text[currentIndex] == "\n" {
                newlineCount += 1
            }
            if newlineCount < lines || currentIndex == text.index(before: text.endIndex) {
                contextEnd = text.index(after: currentIndex)
            }
            currentIndex = text.index(after: currentIndex)
        }

        return String(text[contextStart..<contextEnd]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    // MARK: - LLM keyword extraction (keywords only)
    private struct SearchPlan {
        let keywords: [String]
    }

    // MARK: - Ollama availability
    private var lastOllamaUnreachableLog: Date?

    private func shouldAttemptOllamaRequest(baseURL: String, label: String) -> Bool {
        // If the user disabled RAG or uses a different base URL, this still applies.
        // We only special-case localhost for a quick early return when it's clearly not running.
        guard let url = URL(string: baseURL) else { return false }

        let host = (url.host ?? "").lowercased()
        let isLocalhost = host == "localhost" || host == "127.0.0.1" || host == "::1"

        // If it's localhost and the service isn't running, the call will fail with -1003/-1004/-1009.
        // We can't synchronously probe without adding more work, so we just throttle logs.
        if isLocalhost {
            // Allow attempts, but throttle repeated error logging to once every 10 seconds.
            if let last = lastOllamaUnreachableLog, Date().timeIntervalSince(last) < 10 {
                return true
            }
        }

        return true
    }

    private func noteOllamaUnreachableIfNeeded(_ error: Error, baseURL: String, label: String) {
        guard let urlError = error as? URLError else { return }

        switch urlError.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost, .timedOut:
            let now = Date()
            if lastOllamaUnreachableLog == nil || now.timeIntervalSince(lastOllamaUnreachableLog!) >= 10 {
                lastOllamaUnreachableLog = now
                print("⚠️ \(label): Ollama unreachable at \(baseURL). Start Ollama or update Settings. (\(urlError.code.rawValue))")
            }
        default:
            break
        }
    }

    private func buildSearchPlan(withLLM query: String) async -> SearchPlan {
        // Cache hit
        if let cached = keywordCache[query] {
            return SearchPlan(keywords: cached)
        }

        let baseURL = config.ollamaBaseURL
        let model   = config.ollamaChatModel

        guard shouldAttemptOllamaRequest(baseURL: baseURL, label: "Keyword LLM") else {
            return SearchPlan(keywords: [])
        }

        guard let url = URL(string: "\(baseURL)/api/chat") else {
            print("Invalid Ollama URL for keyword extraction")
            return SearchPlan(keywords: [])
        }

        let systemPrompt = [
            "You are a keyword extraction assistant for searching PDF documents.",
            "Your job is to pick 2-5 highly relevant keywords or short phrases from the user's question.",
            "Return ONLY a JSON array of strings, no extra text. Example:",
            "[\"chapter 3\", \"chapter 3 title\", \"section 3\"]"
        ].joined(separator: "\n")

        let userMessage = [
            "Question: \(query)",
            "",
            "Extract 2-5 search keywords or phrases."
        ].joined(separator: "\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user",   "content": userMessage]
        ]

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false
        ]
        let keywordOptions = config.keywordOptions
        if !keywordOptions.isEmpty {
            payload["options"] = keywordOptions
        }

        func parseKeywordArray(from raw: String) -> [String]? {
            // 1) Trim and strip optional ```json fences
            var cleaned = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if cleaned.hasPrefix("```") {
                // Remove opening fence line (``` or ```json)
                if let firstNewline = cleaned.range(of: "\n") {
                    cleaned = String(cleaned[firstNewline.upperBound...])
                }
                // Remove closing fence if present
                if let closingFence = cleaned.range(of: "```", options: .backwards) {
                    cleaned = String(cleaned[..<closingFence.lowerBound])
                }
                cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }

            // 2) Try direct JSON array decode
            if let data = cleaned.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                return arr
            }

            // 3) Fallback: extract first [...] substring (handles extra text around JSON)
            if let start = cleaned.firstIndex(of: "["),
               let end = cleaned.lastIndex(of: "]"),
               start < end {
                let slice = String(cleaned[start...end])
                if let data = slice.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    return arr
                }
            }

            return nil
        }

        func logHTTPFailure(_ http: HTTPURLResponse, data: Data, label: String) {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            print("❌ \(label) failed with status: \(http.statusCode)")
            print("❌ \(label) response: \(body)")
        }

        do {
            // First attempt (with options if present)
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            // Retry once on timeout
            var (data, response) = try await withTimeoutRetry(label: "Keyword LLM", maxRetries: 1) {
                try await URLSession.shared.data(for: request)
            }

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logHTTPFailure(http, data: data, label: "Keyword LLM")

                // Retry once without options (some servers reject unknown/empty options)
                if payload["options"] != nil {
                    var retryPayload = payload
                    retryPayload.removeValue(forKey: "options")
                    request.httpBody = try JSONSerialization.data(withJSONObject: retryPayload)

                    let retry = try await withTimeoutRetry(label: "Keyword LLM (retry)", maxRetries: 1) {
                        try await URLSession.shared.data(for: request)
                    }
                    data = retry.0
                    response = retry.1

                    if let retryHTTP = response as? HTTPURLResponse, retryHTTP.statusCode != 200 {
                        logHTTPFailure(retryHTTP, data: data, label: "Keyword LLM (retry)")
                        return SearchPlan(keywords: [])
                    }
                } else {
                    return SearchPlan(keywords: [])
                }
            }

            // Case 1: model returns a raw JSON array of strings at the top level
            if let rootArray = try? JSONSerialization.jsonObject(with: data) as? [String] {
                let keywords = rootArray
                    .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                print("Keywords (direct array) for '\(query)': \(keywords)")
                keywordCache[query] = keywords
                return SearchPlan(keywords: keywords)
            }

            // Case 2: Ollama chat-style JSON with message.content containing the array
            guard let root    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = root["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                print("Keyword LLM returned unexpected JSON")
                return SearchPlan(keywords: [])
            }

            if let arr = parseKeywordArray(from: content) {
                let keywords = arr
                    .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                print("Keywords (parsed content) for '\(query)': \(keywords)")
                keywordCache[query] = keywords
                return SearchPlan(keywords: keywords)
            }

            print("Could not parse keyword array from LLM content: \(content)")
            return SearchPlan(keywords: [])
        } catch {
            noteOllamaUnreachableIfNeeded(error, baseURL: baseURL, label: "Keyword LLM")
            print("Keyword LLM error: \(error.localizedDescription)")
            return SearchPlan(keywords: [])
        }
    }

    // MARK: - Keyword fallback helpers

    private func fallbackKeywordsFromQuery(_ query: String, max: Int) -> [String] {
        // Very fast local fallback: pull distinct meaningful tokens from the user's question.
        let stop: Set<String> = [
            "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with", "at", "by", "from",
            "is", "are", "was", "were", "be", "been", "being",
            "what", "why", "how", "when", "where", "which", "who",
            "explain", "define", "meaning", "does", "do", "did", "can", "could", "should", "would"
        ]

        let tokens = normalizeTokens(query)
            .filter { !stop.contains($0) }

        var seen = Set<String>()
        var out: [String] = []
        for t in tokens {
            guard !seen.contains(t) else { continue }
            seen.insert(t)
            out.append(t)
            if out.count >= max { break }
        }
        return out
    }

    private func buildSearchPlanBroader(withLLM query: String, attempt: Int) async -> SearchPlan {
        // Attempt 1: ask for MORE and BROADER keywords/phrases.
        // Attempt 2: ask for even broader single-word terms and synonyms.
        let baseURL = config.ollamaBaseURL
        let model   = config.ollamaChatModel

        guard shouldAttemptOllamaRequest(baseURL: baseURL, label: "Keyword LLM broader") else {
            return SearchPlan(keywords: [])
        }

        guard let url = URL(string: "\(baseURL)/api/chat") else {
            return SearchPlan(keywords: [])
        }

        let systemPrompt = [
            "You are a keyword extraction assistant for searching PDF documents.",
            "Your job is to generate search keywords that maximize recall.",
            "Prefer nouns/proper nouns/technical terms.",
            "Return ONLY a JSON array of strings, no extra text."
        ].joined(separator: "\n")

        let userMessage: String
        if attempt == 1 {
            userMessage = [
                "Question: \(query)",
                "",
                "The previous search returned zero results.",
                "Generate 6-12 broader keywords or short phrases.",
                "Guidelines:",
                "- include alternative spellings and abbreviations",
                "- include shorter variants (single words) and longer phrases",
                "- avoid overly specific quotes"
            ].joined(separator: "\n")
        } else {
            userMessage = [
                "Question: \(query)",
                "",
                "The previous broader keyword search still returned zero results.",
                "Generate 8-16 very broad search terms.",
                "Guidelines:",
                "- mostly single words",
                "- include likely synonyms",
                "- include related chapter/section labels (e.g., 'introduction', 'overview') if plausible",
                "- maximize recall"
            ].joined(separator: "\n")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user",   "content": userMessage]
        ]

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false
        ]
        let keywordOptions = config.keywordOptions
        if !keywordOptions.isEmpty {
            payload["options"] = keywordOptions
        }

        func parseKeywordArray(from raw: String) -> [String]? {
            var cleaned = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if cleaned.hasPrefix("```") {
                if let firstNewline = cleaned.range(of: "\n") {
                    cleaned = String(cleaned[firstNewline.upperBound...])
                }
                if let closingFence = cleaned.range(of: "```", options: .backwards) {
                    cleaned = String(cleaned[..<closingFence.lowerBound])
                }
                cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }

            if let data = cleaned.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                return arr
            }

            if let start = cleaned.firstIndex(of: "["),
               let end = cleaned.lastIndex(of: "]"),
               start < end {
                let slice = String(cleaned[start...end])
                if let data = slice.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    return arr
                }
            }
            return nil
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            // Retry once on timeout
            let (data, response) = try await withTimeoutRetry(label: "Keyword LLM broader (attempt=\(attempt))", maxRetries: 1) {
                try await URLSession.shared.data(for: request)
            }

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return SearchPlan(keywords: [])
            }

            // Accept either direct array or chat-style {message:{content:"[...]"}}
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                let cleaned = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                return SearchPlan(keywords: cleaned)
            }

            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = root["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  let arr = parseKeywordArray(from: content) else {
                return SearchPlan(keywords: [])
            }

            let cleaned = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return SearchPlan(keywords: cleaned)
        } catch {
            noteOllamaUnreachableIfNeeded(error, baseURL: baseURL, label: "Keyword LLM broader")
            return SearchPlan(keywords: [])
        }
    }

    private func isSnippetRelevantToQuestion(question: String, snippet: String) async -> Bool {
        let baseURL = config.ollamaBaseURL
        let model   = config.ollamaChatModel

        guard shouldAttemptOllamaRequest(baseURL: baseURL, label: "Relevance LLM") else {
            // Fail open: treat as relevant
            return true
        }

        guard let url = URL(string: "\(baseURL)/api/chat") else {
            print("Invalid Ollama URL for relevance filtering")
            // Fail open: treat as relevant
            return true
        }

        let systemPrompt = [
            "You are a relevance classifier for PDF question answering.",
            "",
            "Your job for each snippet is to decide whether it is relevant to answering the user's question.",
            "",
            "Return ONLY a single JSON object with this shape, no extra text:",
            "{",
            "  \"relevant\": true/false",
            "}"
        ].joined(separator: "\n")

        let userMessage = [
            "Question:",
            "\(question)",
            "",
            "Snippet:",
            "\(snippet)",
            "",
            "Decide relevance."
        ].joined(separator: "\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user",   "content": userMessage]
        ]

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false
        ]
        let relevanceOptions = config.relevanceOptions
        if !relevanceOptions.isEmpty {
            payload["options"] = relevanceOptions
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            // Retry once on timeout
            var (data, response) = try await withTimeoutRetry(label: "Relevance LLM", maxRetries: 1) {
                try await URLSession.shared.data(for: request)
            }

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                print("⚠️ Relevance LLM status: \(http.statusCode), treating as relevant")
                print("⚠️ Relevance LLM response: \(body)")

                // Retry once without options
                if payload["options"] != nil {
                    var retryPayload = payload
                    retryPayload.removeValue(forKey: "options")
                    request.httpBody = try JSONSerialization.data(withJSONObject: retryPayload)

                    let retry = try await withTimeoutRetry(label: "Relevance LLM (retry)", maxRetries: 1) {
                        try await URLSession.shared.data(for: request)
                    }
                    data = retry.0
                    response = retry.1

                    if let retryHTTP = response as? HTTPURLResponse, retryHTTP.statusCode != 200 {
                        let retryBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                        print("⚠️ Relevance LLM retry status: \(retryHTTP.statusCode), treating as relevant")
                        print("⚠️ Relevance LLM retry response: \(retryBody)")
                        return true
                    }
                } else {
                    return true
                }
            }

            // Try top-level JSON with {"relevant": ...}
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let relAny = root["relevant"],
               let relevant = parseFlexibleBool(relAny) {
                print("Relevance: \(relevant)")
                return relevant
            }

            // Otherwise assume Ollama chat-style JSON where JSON is inside message.content
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = root["message"] as? [String: Any],
               let content = message["content"] as? String,
               let innerData = extractJSONFromContent(content),
               let obj = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
               let relAny = obj["relevant"],
               let relevant = parseFlexibleBool(relAny) {
                print("Relevance: \(relevant)")
                return relevant
            }

            // Avoid nested escaped quotes inside string interpolation (can confuse the parser)
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            print("Relevance LLM unexpected JSON, treating as relevant: \(raw)")
            return true
        } catch {
            noteOllamaUnreachableIfNeeded(error, baseURL: baseURL, label: "Relevance LLM")
            print("Relevance LLM error: \(error.localizedDescription), treating as relevant")
            return true
        }
    }

    // MARK: - Network retry helpers

    private func isTimeoutError(_ error: Error) -> Bool {
        // URLSession timeouts typically surface as URLError.timedOut.
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorTimedOut
        }
        return false
    }

    private func withTimeoutRetry<T>(
        label: String,
        maxRetries: Int,
        initialBackoffMs: UInt64 = 150,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var attempt = 0
        var backoff = initialBackoffMs

        while true {
            do {
                return try await operation()
            } catch {
                attempt += 1
                let canRetry = isTimeoutError(error) && attempt <= maxRetries
                if !canRetry {
                    throw error
                }

                // Small exponential backoff.
                let delayNs = backoff * 1_000_000
                print("⏱️ \(label) timed out. Retrying (attempt \(attempt)/\(maxRetries + 1)) after \(backoff)ms")
                try? await Task.sleep(nanoseconds: delayNs)
                backoff = min(backoff * 2, 1_200)
            }
        }
    }

    // MARK: - JSON helpers
    private func parseFlexibleBool(_ value: Any?) -> Bool? {
        if value == nil { return nil }
        let unwrapped: Any = value!

        // JSONSerialization often bridges booleans as NSNumber.
        if let number = unwrapped as? NSNumber {
            return number.boolValue
        }

        if let boolValue = unwrapped as? Bool {
            return boolValue
        }

        // Accept common string representations like "true", "yes", "y", etc.
        if let stringValue = unwrapped as? String {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()

            if lower == "true" || lower == "yes" || lower == "y" || lower == "1" {
                return true
            }
            if lower == "false" || lower == "no" || lower == "n" || lower == "0" {
                return false
            }
            return nil
        }

        return nil
    }

    private func extractJSONFromContent(_ content: String) -> Data? {
        var trimmed = content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // Strip opening fence
        if trimmed.hasPrefix("```") {
            if let firstNewline = trimmed.range(of: "\n") {
                trimmed = String(trimmed[firstNewline.upperBound...])
            }
        }

        // Strip closing fence if present
        if let closingFenceRange = trimmed.range(of: "```", options: .backwards) {
            trimmed = String(trimmed[..<closingFenceRange.lowerBound])
        }

        trimmed = trimmed.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.data(using: .utf8)
    }

    private func normalizeTokens(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let parts = lowered.split { ch in
            !(ch.isLetter || ch.isNumber)
        }
        // Keep tokens reasonably sized to avoid noise
        return parts.map(String.init).filter { $0.count >= 2 }
    }

    private func fastScore(question: String, snippet: String) -> Double {
        let qTokens = normalizeTokens(question)
        guard !qTokens.isEmpty else { return 0 }

        let sTokens = normalizeTokens(snippet)
        guard !sTokens.isEmpty else { return 0 }

        let qSet = Set(qTokens)
        let sSet = Set(sTokens)

        let overlap = Double(qSet.intersection(sSet).count)
        let coverage = overlap / Double(max(1, qSet.count))

        // Small boosts for exact substring matches
        var boost: Double = 0
        let qCompact = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !qCompact.isEmpty, snippet.lowercased().contains(qCompact) {
            boost += 0.5
        }

        // Prefer shorter snippets slightly (they're more "focused")
        let lengthPenalty = min(1.0, Double(snippet.count) / 1200.0) * 0.15

        return coverage + boost - lengthPenalty
    }

    private func clampSnippet(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars))
    }

    private func canonicalizeForDedupe(_ text: String) -> String {
        // Collapse whitespace, lowercase.
        let collapsed = text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        // Truncate for speed and stable hashing
        return String(collapsed.prefix(500))
    }

    /// Build additional query terms deterministically from the raw question.
    /// This helps when the LLM returns overly generic keywords (e.g. only "chapter").
    private func queryDerivedTerms(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let lower = q.lowercased()

        // Capture common structured tokens like "chapter 3", "section 2.1", "figure 4", etc.
        // This is intentionally simple and fast.
        let patterns: [String] = [
            "(chapter\\s+\\d+(?:\\.\\d+)*)",
            "(section\\s+\\d+(?:\\.\\d+)*)",
            "(figure\\s+\\d+(?:\\.\\d+)*)",
            "(table\\s+\\d+(?:\\.\\d+)*)",
            "(appendix\\s+[a-z])"
        ]

        var out: [String] = []
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let ns = lower as NSString
            let matches = re.matches(in: lower, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                guard m.numberOfRanges > 1 else { continue }
                let s = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(s) }
            }
        }

        // If the query contains both "chapter" and a number but the regex didn't catch it, add it.
        if out.isEmpty {
            // very small heuristic for things like "chapter3"
            if let re = try? NSRegularExpression(pattern: "chapter\\s*\\d+", options: []) {
                let ns = lower as NSString
                let matches = re.matches(in: lower, options: [], range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    let s = ns.substring(with: m.range).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    if !s.isEmpty { out.append(s) }
                }
            }
        }

        // Also add a compact version of the question without leading interrogatives.
        // Example: "what is chapter 3" -> "chapter 3" (already handled) + "chapter 3?" stripped.
        let stripped = lower
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "what is ", with: "")
            .replacingOccurrences(of: "what's ", with: "")
            .replacingOccurrences(of: "whats ", with: "")
            .replacingOccurrences(of: "tell me about ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count >= 3, stripped != lower {
            out.append(stripped)
        }

        // De-dupe while preserving order.
        var seen = Set<String>()
        var unique: [String] = []
        for t in out {
            let k = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            if seen.contains(k) { continue }
            seen.insert(k)
            unique.append(k)
        }
        return unique
    }

    /// Merge LLM keywords with the raw query and query-derived phrases.
    /// We always keep the raw query/phrases near the front to prevent overly generic searches.
    private func buildSearchTerms(question: String, llmKeywords: [String]) -> [String] {
        let derived = queryDerivedTerms(question)

        // Start with derived phrases ("chapter 3"), then LLM keywords, then a fallback to the raw question.
        var candidates: [String] = []
        candidates.append(contentsOf: derived)
        candidates.append(contentsOf: llmKeywords)
        candidates.append(question)

        // Normalize / de-dupe
        var seen = Set<String>()
        var out: [String] = []
        for c in candidates {
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if seen.contains(t) { continue }
            seen.insert(t)
            out.append(t)
        }

        // If the LLM returned a single generic token like "chapter", keep it but don't let it be the only term.
        if out.count == 1 {
            out.append(contentsOf: fallbackKeywordsFromQuery(question, max: 6))
        }

        return out
    }

    /// Get context for a user's question using LLM keywords + PDFKit search.
    /// In fast mode, we avoid per-snippet LLM relevance calls and instead rank snippets locally.
    func getContextForQuery(_ query: String) async -> (context: String, pages: [Int]) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return ("", []) }

        // Quick cache hit (10 minutes)
        if let cached = contextCache[normalizedQuery], Date().timeIntervalSince(cached.timestamp) < 10 * 60 {
            return (cached.context, cached.pages)
        }

        // 1. Ask LLM for search keywords
        var plan = await buildSearchPlan(withLLM: normalizedQuery)

        func runSearch(for terms: [String]) -> [SearchResult] {
            var all: [SearchResult] = []
            for term in terms {
                let hits = search(query: term,
                                  caseSensitive: config.searchCaseSensitive,
                                  wholeWords:   config.searchWholeWords)
                all.append(contentsOf: hits)
            }
            return all
        }

        // Attempt 0: use merged terms (derived phrases + LLM keywords + raw query)
        var terms = buildSearchTerms(question: normalizedQuery, llmKeywords: plan.keywords)
        var allResults = runSearch(for: terms)

        // If no hits, broaden keywords and retry twice (escalating)
        if allResults.isEmpty {
            plan = await buildSearchPlanBroader(withLLM: normalizedQuery, attempt: 1)
            terms = buildSearchTerms(question: normalizedQuery, llmKeywords: plan.keywords)
            allResults = runSearch(for: terms)
        }

        if allResults.isEmpty {
            plan = await buildSearchPlanBroader(withLLM: normalizedQuery, attempt: 2)
            terms = buildSearchTerms(question: normalizedQuery, llmKeywords: plan.keywords)
            allResults = runSearch(for: terms)
        }

        // Final fallback: local tokens only (no LLM)
        if allResults.isEmpty {
            let local = queryDerivedTerms(normalizedQuery) + fallbackKeywordsFromQuery(normalizedQuery, max: 10)
            allResults = runSearch(for: local)
        }

        guard !allResults.isEmpty else {
            return ("", [])
        }

        // 3. Group by page
        var pageResults: [Int: [SearchResult]] = [:]
        for res in allResults {
            pageResults[res.pageNumber, default: []].append(res)
        }

        if config.fastMode {
            struct Scored {
                let page: Int
                let result: SearchResult
                let score: Double
            }

            var scored: [Scored] = []
            scored.reserveCapacity(allResults.count)
            for res in allResults {
                let score = fastScore(question: normalizedQuery, snippet: res.context)
                scored.append(Scored(page: res.pageNumber, result: res, score: score))
            }

            scored.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.page != b.page { return a.page < b.page }
                return a.result.context.count < b.result.context.count
            }

            let maxSnippetsGlobal = 12
            let topScored = Array(scored.prefix(maxSnippetsGlobal))

            var dedupedPerPage: [Int: [SearchResult]] = [:]
            var globalSeen = Set<String>()

            for item in topScored {
                let canonical = canonicalizeForDedupe(item.result.context)
                guard !canonical.isEmpty else { continue }
                guard !globalSeen.contains(canonical) else { continue }
                globalSeen.insert(canonical)

                var r = item.result
                r.context = clampSnippet(item.result.context, maxChars: 700)
                dedupedPerPage[item.page, default: []].append(r)
            }

            dedupedPerPage = dedupedPerPage.filter { !$0.value.isEmpty }
            guard !dedupedPerPage.isEmpty else {
                return ("", [])
            }

            let built = buildContextFrom(pageResults: dedupedPerPage, forceSnippetsOnly: true)
            contextCache[normalizedQuery] = (built.0, built.1, Date())
            return built
        }

        // QUALITY MODE: Apply relevance filter per snippet (parallel) with early exit heuristic
        let targetRelevant = config.minRelevantSnippetsBeforeStop

        // Flatten to preserve a deterministic-ish order.
        let pairs: [(page: Int, result: SearchResult)] = pageResults
            .sorted(by: { $0.key < $1.key })
            .flatMap { page, results in results.map { (page: page, result: $0) } }

        var acceptedByPage: [Int: [SearchResult]] = [:]
        acceptedByPage.reserveCapacity(pageResults.count)

        // Limit concurrency to avoid overwhelming Ollama.
        let maxConcurrent = 3
        var totalRelevant = 0

        var i = 0
        while i < pairs.count, totalRelevant < targetRelevant {
            let batch = Array(pairs[i..<min(i + maxConcurrent, pairs.count)])
            i += batch.count

            // Run relevance checks in parallel for this batch.
            let results: [(Int, SearchResult, Bool)] = await withTaskGroup(of: (Int, SearchResult, Bool).self) { group in
                for item in batch {
                    group.addTask { [weak self] in
                        guard let self else { return (item.page, item.result, false) }
                        let snippet = item.result.context
                        let key = "\(normalizedQuery)\n---\n\(snippet)".hashValue.description

                        if let cached = await self.relevanceDecisionCache.get(key) {
                            return (item.page, item.result, cached)
                        }

                        let rel = await self.isSnippetRelevantToQuestion(question: normalizedQuery, snippet: snippet)
                        await self.relevanceDecisionCache.set(key, value: rel)
                        return (item.page, item.result, rel)
                    }
                }

                var out: [(Int, SearchResult, Bool)] = []
                for await r in group {
                    out.append(r)
                }
                return out
            }

            // Apply in the order they returned (good enough for relevance filtering)
            for (page, result, isRelevant) in results {
                if isRelevant {
                    acceptedByPage[page, default: []].append(result)
                    totalRelevant += 1
                    if totalRelevant >= targetRelevant { break }
                }
            }
        }

        acceptedByPage = acceptedByPage.filter { !$0.value.isEmpty }
        guard !acceptedByPage.isEmpty else {
            return ("", [])
        }

        let built = buildContextFrom(pageResults: acceptedByPage)
        contextCache[normalizedQuery] = (built.0, built.1, Date())
        return built
    }

    private func buildContextFrom(pageResults: [Int: [SearchResult]]) -> (String, [Int]) {
        buildContextFrom(pageResults: pageResults, forceSnippetsOnly: false)
    }

    private func buildContextFrom(pageResults: [Int: [SearchResult]], forceSnippetsOnly: Bool) -> (String, [Int]) {
        // Rank pages by number of matches, then page number
        let sortedPages = pageResults.keys.sorted { p1, p2 in
            let c1 = pageResults[p1]?.count ?? 0
            let c2 = pageResults[p2]?.count ?? 0
            if c1 != c2 { return c1 > c2 }
            return p1 < p2
        }

        let maxPages      = config.maxPagesDisplay
        let selectedPages = Array(sortedPages.prefix(maxPages))

        var context = ""
        for pageNum in selectedPages {
            let matches = pageResults[pageNum] ?? []
            context += "[Page \(pageNum) - \(matches.count) matches]\n"

            let includeFullPage = (!forceSnippetsOnly) && config.includePageContext

            if includeFullPage {
                if let pageText = pdfPages[pageNum] {
                    context += pageText + "\n\n"
                }
            } else {
                for (index, result) in matches.prefix(4).enumerated() {
                    context += "Snippet \(index + 1): \(clampSnippet(result.context, maxChars: 700))\n"
                }
                context += "\n"
            }

            if context.count >= config.maxRAGContextChars {
                context = String(context.prefix(config.maxRAGContextChars))
                break
            }
        }

        print("Retrieved context from \(selectedPages.count) pages (fastMode=\(config.fastMode)) (\(context.count) chars)")
        return (context, selectedPages)
    }

    func clear() {
        searchResults = []
        currentSearchQuery = ""
        pdfPages = [:]
        keywordCache = [:]
        contextCache = [:]
        Task { await relevanceDecisionCache.clear() }
    }
}

// MARK: - Small helpers
private extension Array {
    /// Split the array into (matching, nonMatching) based on a predicate
    func partitioned(_ belongsInFirst: (Element) -> Bool) -> ([Element], [Element]) {
        var first: [Element] = []
        var second: [Element] = []
        for element in self {
            if belongsInFirst(element) {
                first.append(element)
            } else {
                second.append(element)
            }
        }
        return (first, second)
    }
}
