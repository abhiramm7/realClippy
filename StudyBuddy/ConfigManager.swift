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
                    maxChatHistoryMessages: 10
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
        config?.defaults.ollamaBaseURL ?? "http://localhost:11434"
    }

    var useRAG: Bool {
        UserDefaults.standard.object(forKey: "useRAG") as? Bool ?? config?.defaults.useRAG ?? true
    }

    var chatTimeout: Double {
        config?.defaults.chatTimeout ?? 60.0
    }

    var defaultChatWidth: CGFloat {
        CGFloat(config?.ui.defaultChatWidth ?? 300)
    }

    var showWelcomeMessage: Bool {
        config?.ui.showWelcomeMessage ?? true
    }

    var autoIndexOnOpen: Bool {
        config?.ui.autoIndexOnOpen ?? true
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

    var maxPagesDisplay: Int {
        config?.rag.maxPagesDisplay ?? 10
    }

    var includePageContext: Bool {
        config?.rag.includePageContext ?? true
    }

    var maxRAGContextChars: Int {
        config?.rag.maxContextChars ?? 4000
    }

    var minRelevantSnippetsBeforeStop: Int {
        config?.rag.minRelevantSnippetsBeforeStop ?? 5
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

    func saveUseRAG(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "useRAG")
    }

    func saveFastMode(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "fastMode")
    }

    func saveMaxChatHistoryMessages(_ limit: Int) {
        UserDefaults.standard.set(max(1, limit), forKey: "maxChatHistoryMessages")
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
