import Foundation

class ConfigManager {
    static let shared = ConfigManager()

    private var config: Config?

    struct Config: Codable {
        let defaults: Defaults
        let ui: UISettings
        let search: SearchSettings?
        let rag: RAGSettings
        let ollamaOptions: OllamaOptions?
        let models: ModelRecommendations?

        struct Defaults: Codable {
            let ollamaChatModel: String?
            let ollamaModel: String? // Legacy support
            let ollamaBaseURL: String
            let useRAG: Bool
            let chatTimeout: Double
        }

        struct UISettings: Codable {
            let defaultChatWidth: Double
            let showWelcomeMessage: Bool
            let autoIndexOnOpen: Bool
            /// Fast mode trades some answer quality for much lower latency.
            /// When enabled, the app avoids per-snippet LLM relevance calls and keeps prompts shorter.
            let fastMode: Bool?
            /// Max number of chat messages (excluding system prompt) to send with each request.
            /// Lower values keep prompts smaller and speed up responses.
            let maxChatHistoryMessages: Int?

            // New UI tuning knobs
            let minChatWidth: Double?
            let maxChatWidthFraction: Double?
            let chatBubbleMaxWidth: Double?

            // Settings popover sizing
            let settingsPopoverWidth: Double?

            // PDF indexing retry behavior
            let pdfIndexMaxAttempts: Int?
            let pdfIndexRetryBaseDelaySeconds: Double?
        }

        struct SearchSettings: Codable {
            let caseSensitive: Bool
            let wholeWords: Bool
            let maxResultsPerPage: Int
            let contextLines: Int
            let highlightMatches: Bool
        }

        struct RAGSettings: Codable {
            let enableAutoIndexing: Bool
            let showPageNumbers: Bool
            let maxPagesDisplay: Int
            let includePageContext: Bool
            let maxContextChars: Int?
            let minRelevantSnippetsBeforeStop: Int?
        }

        struct OllamaOptions: Codable {
            let chat: GenerationOptions?
            let keywords: GenerationOptions?
            let relevance: GenerationOptions?

            struct GenerationOptions: Codable {
                let temperature: Double?
                let top_p: Double?
                let num_predict: Int?
            }
        }

        struct ModelRecommendations: Codable {
            let recommendedChat: [String]
        }
    }

    private init() {
        loadConfig()
    }

    private func loadConfig() {
        // Try to load from bundle
        if let url = Bundle.main.url(forResource: "config", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let loadedConfig = try? JSONDecoder().decode(Config.self, from: data) {
            self.config = loadedConfig
            print("✅ Configuration loaded from config.json")
        } else {
            // Fallback to hardcoded defaults
            print("⚠️ Could not load config.json, using hardcoded defaults")
            self.config = Config(
                defaults: Config.Defaults(
                    ollamaChatModel: "ministral-3:3b",
                    ollamaModel: nil,
                    ollamaBaseURL: "http://localhost:11434",
                    useRAG: true,
                    chatTimeout: 60.0
                ),
                ui: Config.UISettings(
                    defaultChatWidth: 300,
                    showWelcomeMessage: true,
                    autoIndexOnOpen: true,
                    fastMode: true,
                    maxChatHistoryMessages: 10,
                    minChatWidth: 240,
                    maxChatWidthFraction: 0.7,
                    chatBubbleMaxWidth: 300,
                    settingsPopoverWidth: 360,
                    pdfIndexMaxAttempts: 10,
                    pdfIndexRetryBaseDelaySeconds: 0.1
                ),
                search: Config.SearchSettings(
                    caseSensitive: false,
                    wholeWords: false,
                    maxResultsPerPage: 10,
                    contextLines: 2,
                    highlightMatches: true
                ),
                rag: Config.RAGSettings(
                    enableAutoIndexing: true,
                    showPageNumbers: true,
                    maxPagesDisplay: 10,
                    includePageContext: true,
                    maxContextChars: 4000,
                    minRelevantSnippetsBeforeStop: 5
                ),
                ollamaOptions: Config.OllamaOptions(
                    chat: Config.OllamaOptions.GenerationOptions(
                        temperature: nil,
                        top_p: nil,
                        num_predict: nil
                    ),
                    keywords: Config.OllamaOptions.GenerationOptions(
                        temperature: nil,
                        top_p: nil,
                        num_predict: nil
                    ),
                    relevance: Config.OllamaOptions.GenerationOptions(
                        temperature: nil,
                        top_p: nil,
                        num_predict: nil
                    )
                ),
                models: Config.ModelRecommendations(
                    recommendedChat: ["ministral-3:3b", "llama3.2", "llama3.1:8b"]
                )
            )
        }
    }

    // MARK: - Accessors

    var ollamaModel: String {
        // For backwards compatibility - returns chat model
        ollamaChatModel
    }

    var ollamaChatModel: String {
        // Check UserDefaults first (user override)
        if let userModel = UserDefaults.standard.string(forKey: "ollamaChatModel") {
            return userModel
        }
        // Legacy key support
        if let userModel = UserDefaults.standard.string(forKey: "ollamaModel") {
            return userModel
        }
        // Config file
        if let chatModel = config?.defaults.ollamaChatModel {
            return chatModel
        }
        if let legacyModel = config?.defaults.ollamaModel {
            return legacyModel
        }
        // Final fallback
        return "ministral-3:3b"
    }

    var ollamaBaseURL: String {
        if let userURL = UserDefaults.standard.string(forKey: "ollamaBaseURL") {
            return userURL
        }
        return config?.defaults.ollamaBaseURL ?? "http://localhost:11434"
    }

    var useRAG: Bool {
        UserDefaults.standard.object(forKey: "useRAG") as? Bool ?? config?.defaults.useRAG ?? true
    }

    var chatTimeout: Double {
        if UserDefaults.standard.object(forKey: "chatTimeout") != nil {
            let v = UserDefaults.standard.double(forKey: "chatTimeout")
            return max(1.0, v)
        }
        return config?.defaults.chatTimeout ?? 60.0
    }

    var defaultChatWidth: CGFloat {
        CGFloat(config?.ui.defaultChatWidth ?? 300)
    }

    var showWelcomeMessage: Bool {
        config?.ui.showWelcomeMessage ?? true
    }

    var autoIndexOnOpen: Bool {
        if let v = UserDefaults.standard.object(forKey: "autoIndexOnOpen") as? Bool {
            return v
        }
        return config?.ui.autoIndexOnOpen ?? true
    }

    /// Fast Mode trades some answer quality for much lower latency.
    /// UserDefaults override key: "fastMode"
    var fastMode: Bool {
        if let v = UserDefaults.standard.object(forKey: "fastMode") as? Bool {
            return v
        }
        return config?.ui.fastMode ?? true
    }

    /// Max number of chat messages (excluding system prompt) to send with each request.
    /// UserDefaults override key: "maxChatHistoryMessages"
    var maxChatHistoryMessages: Int {
        if let v = UserDefaults.standard.object(forKey: "maxChatHistoryMessages") as? Int {
            return max(1, v)
        }
        return max(1, config?.ui.maxChatHistoryMessages ?? 10)
    }

    var maxPagesDisplay: Int {
        if let v = UserDefaults.standard.object(forKey: "maxPagesDisplay") as? Int {
            return max(1, v)
        }
        return config?.rag.maxPagesDisplay ?? 10
    }

    var includePageContext: Bool {
        if let v = UserDefaults.standard.object(forKey: "includePageContext") as? Bool {
            return v
        }
        return config?.rag.includePageContext ?? true
    }

    var maxRAGContextChars: Int {
        if let v = UserDefaults.standard.object(forKey: "maxRAGContextChars") as? Int {
            return max(0, v)
        }
        return config?.rag.maxContextChars ?? 4000
    }

    var minRelevantSnippetsBeforeStop: Int {
        if let v = UserDefaults.standard.object(forKey: "minRelevantSnippetsBeforeStop") as? Int {
            return max(1, v)
        }
        return config?.rag.minRelevantSnippetsBeforeStop ?? 5
    }

    // UI tuning overrides
    var minChatWidth: CGFloat {
        if UserDefaults.standard.object(forKey: "minChatWidth") != nil {
            let v = UserDefaults.standard.double(forKey: "minChatWidth")
            return CGFloat(max(100.0, v))
        }
        return CGFloat(config?.ui.minChatWidth ?? 240)
    }

    var maxChatWidthFraction: CGFloat {
        if UserDefaults.standard.object(forKey: "maxChatWidthFraction") != nil {
            let v = UserDefaults.standard.double(forKey: "maxChatWidthFraction")
            return CGFloat(min(max(0.1, v), 0.95))
        }
        return CGFloat(config?.ui.maxChatWidthFraction ?? 0.7)
    }

    var chatBubbleMaxWidth: CGFloat {
        if UserDefaults.standard.object(forKey: "chatBubbleMaxWidth") != nil {
            let v = UserDefaults.standard.double(forKey: "chatBubbleMaxWidth")
            return CGFloat(max(150.0, v))
        }
        return CGFloat(config?.ui.chatBubbleMaxWidth ?? 300)
    }

    var settingsPopoverWidth: CGFloat {
        if UserDefaults.standard.object(forKey: "settingsPopoverWidth") != nil {
            let v = UserDefaults.standard.double(forKey: "settingsPopoverWidth")
            return CGFloat(max(260.0, v))
        }
        return CGFloat(config?.ui.settingsPopoverWidth ?? 360)
    }

    var pdfIndexMaxAttempts: Int {
        if let v = UserDefaults.standard.object(forKey: "pdfIndexMaxAttempts") as? Int {
            return max(1, v)
        }
        return max(1, config?.ui.pdfIndexMaxAttempts ?? 10)
    }

    var pdfIndexRetryBaseDelaySeconds: Double {
        if UserDefaults.standard.object(forKey: "pdfIndexRetryBaseDelaySeconds") != nil {
            let v = UserDefaults.standard.double(forKey: "pdfIndexRetryBaseDelaySeconds")
            return max(0.0, v)
        }
        return max(0.0, config?.ui.pdfIndexRetryBaseDelaySeconds ?? 0.1)
    }

    // Search settings
    var searchCaseSensitive: Bool {
        config?.search?.caseSensitive ?? false
    }

    var searchWholeWords: Bool {
        config?.search?.wholeWords ?? false
    }

    var searchMaxResultsPerPage: Int {
        config?.search?.maxResultsPerPage ?? 10
    }

    var searchContextLines: Int {
        config?.search?.contextLines ?? 2
    }

    var searchHighlightMatches: Bool {
        config?.search?.highlightMatches ?? true
    }

    // RAG settings
    var enableAutoIndexing: Bool {
        config?.rag.enableAutoIndexing ?? true
    }

    var showPageNumbers: Bool {
        config?.rag.showPageNumbers ?? true
    }

    // MARK: - Helpers

    func saveOllamaModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: "ollamaChatModel")
        // Also save to legacy key for compatibility
        UserDefaults.standard.set(model, forKey: "ollamaModel")
    }

    func saveOllamaChatModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: "ollamaChatModel")
    }

    func saveOllamaBaseURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "ollamaBaseURL")
    }

    func saveChatTimeout(_ seconds: Double) {
        UserDefaults.standard.set(max(1.0, seconds), forKey: "chatTimeout")
    }

    func saveAutoIndexOnOpen(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "autoIndexOnOpen")
    }

    func saveMaxPagesDisplay(_ value: Int) {
        UserDefaults.standard.set(max(1, value), forKey: "maxPagesDisplay")
    }

    func saveIncludePageContext(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "includePageContext")
    }

    func saveMaxRAGContextChars(_ value: Int) {
        UserDefaults.standard.set(max(0, value), forKey: "maxRAGContextChars")
    }

    func saveMinRelevantSnippetsBeforeStop(_ value: Int) {
        UserDefaults.standard.set(max(1, value), forKey: "minRelevantSnippetsBeforeStop")
    }

    func saveFastMode(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "fastMode")
    }

    func saveMaxChatHistoryMessages(_ limit: Int) {
        UserDefaults.standard.set(max(1, limit), forKey: "maxChatHistoryMessages")
    }

    func saveMinChatWidth(_ value: Double) {
        UserDefaults.standard.set(max(100.0, value), forKey: "minChatWidth")
    }

    func saveMaxChatWidthFraction(_ value: Double) {
        UserDefaults.standard.set(min(max(0.1, value), 0.95), forKey: "maxChatWidthFraction")
    }

    func saveChatBubbleMaxWidth(_ value: Double) {
        UserDefaults.standard.set(max(150.0, value), forKey: "chatBubbleMaxWidth")
    }

    func saveSettingsPopoverWidth(_ value: Double) {
        UserDefaults.standard.set(max(260.0, value), forKey: "settingsPopoverWidth")
    }

    func savePDFIndexMaxAttempts(_ value: Int) {
        UserDefaults.standard.set(max(1, value), forKey: "pdfIndexMaxAttempts")
    }

    func savePDFIndexRetryBaseDelaySeconds(_ value: Double) {
        UserDefaults.standard.set(max(0.0, value), forKey: "pdfIndexRetryBaseDelaySeconds")
    }

    func saveUseRAG(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "useRAG")
    }

    var recommendedChatModels: [String] {
        config?.models?.recommendedChat ?? ["ministral-3:3b", "llama3.2", "llama3.1:8b"]
    }

    // MARK: - Ollama generation options
    // NOTE: Use `ollamaOptionsDictionary(for:)` to get per-task options.

    enum OllamaTask {
        case chat
        case keywords
        case relevance
    }

    private func options(for task: OllamaTask) -> Config.OllamaOptions.GenerationOptions? {
        switch task {
        case .chat:
            return config?.ollamaOptions?.chat
        case .keywords:
            return config?.ollamaOptions?.keywords
        case .relevance:
            return config?.ollamaOptions?.relevance
        }
    }

    func ollamaOptionsDictionary(for task: OllamaTask) -> [String: Any] {
        guard let opt = options(for: task) else { return [:] }
        var dict: [String: Any] = [:]
        if let t = opt.temperature { dict["temperature"] = t }
        if let p = opt.top_p { dict["top_p"] = p }
        if let n = opt.num_predict { dict["num_predict"] = n }
        return dict
    }
}
