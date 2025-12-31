//
//  ChatService.swift
//  StudyBuddy
//

import Foundation
import Combine
import SwiftUI

let systemPrompt = """
You are the AI assistant inside StudyBuddy, a macOS app for reading PDFs, especially textbooks and research papers.

Your main job is to help the user understand and work with the PDF they have open:
- Answer questions about the document’s content (definitions, explanations, theorems, proofs, examples, figures, tables, etc.).
- Help them quickly locate relevant sections (chapters, sections, appendices, references) using the provided context.
- Clarify concepts, walk through derivations or arguments step by step, and relate ideas across the document when helpful.

## How to use the provided context
- You may receive a `<context>` block that contains excerpts from the current PDF.
- Always **treat `<context>` as the primary source of truth** about this specific document.
- When answering, favor information from `<context>` over your general knowledge.
- If the question clearly depends on details (notation, definitions, assumptions) shown in `<context>`, base your answer directly on those details.

## When context is missing or incomplete
- If `<context>` is empty or does not contain enough information to answer precisely, say so briefly.
- In that case, you may:
  - Answer using general knowledge, but clearly label it as such (e.g., "In general, …").
  - Suggest what part of the document the user might search or scroll to.
  - Propose a follow-up question that would let you be more specific.

## Style and interaction
- Be concise, clear, and structured. Prefer short paragraphs and bullet points when appropriate.
- Use LaTeX-style math notation inside Markdown when helpful, for example:
  - Inline: `$e^{i\\pi} + 1 = 0$`
  - Display: `$$\\int_a^b f(x)\\,dx$$`
- You may use light Markdown formatting (headings, bullet lists, code blocks) to improve readability.
- Describe diagrams or figures in words when needed.
- If a question is ambiguous, ask a short clarifying question instead of guessing.
- If the user asks for a quick reference (e.g., "definition of X", "statement of theorem 3.1"), give the key information first, then optional extra detail.

## General-purpose assistance
- If the user asks something unrelated to the current PDF, you can still help as a general assistant (coding, writing, learning, brainstorming, etc.).
- In those cases, you do not need to reference `<context>` unless it is obviously relevant.
"""

class ChatService: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var streamedText = ""

    private var dataTask: URLSessionDataTask?
    private var onReceiveChunk: ((String) -> Void)?
    private var onComplete: (() -> Void)?
    private var onError: ((String) -> Void)?

    // Streaming throttling
    private var buffer = ""
    private var flushWorkItem: DispatchWorkItem?
    private let flushInterval: TimeInterval = 0.05
    private var isStreamingFinished = false

    override init() {
        super.init()
    }

    // MARK: - Timeout retry helper

    private func isTimeoutError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorTimedOut
        }
        return false
    }

    private func scheduleRetry(afterMs ms: Int, work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    func sendMessageStream(
        messages chatMessages: [ChatMessage],
        apiKey: String,
        onChunk: @escaping (String) -> Void,
        onComplete: (() -> Void)? = nil,
        onError: ((String) -> Void)? = nil
    ) {
        // Cancel any previous stream before starting a new one
        cancelStreaming()

        streamedText = ""
        buffer = ""
        isStreamingFinished = false
        self.onReceiveChunk = onChunk
        self.onComplete = onComplete
        self.onError = onError

        // Build the request once and (if needed) retry issuing it.
        let baseURL = "\(ConfigManager.shared.ollamaBaseURL)/api/chat"
        let model = ConfigManager.shared.ollamaChatModel
        guard let url = URL(string: baseURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = ConfigManager.shared.chatTimeout

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]

        // Keep prompts small by sending only the last N turns.
        // (We always keep the system prompt above.)
        let limit = ConfigManager.shared.maxChatHistoryMessages
        let trimmedChatMessages: [ChatMessage]
        if chatMessages.count > limit {
            trimmedChatMessages = Array(chatMessages.suffix(limit))
        } else {
            trimmedChatMessages = chatMessages
        }

        for msg in trimmedChatMessages {
            var content: String = msg.text
            if msg.context?.isEmpty == false {
                content += "\n<context>\(msg.context ?? "")\n</context>"
            }
            messages.append([
                "role": msg.isUser ? "user" : "assistant",
                "content": content
            ])
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true
        ]

        let options = ConfigManager.shared.ollamaOptionsDictionary(for: .chat)
        if !options.isEmpty {
            payload["options"] = options
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return
        }

        func startStreamAttempt(_ attempt: Int) {
            // Important: create a new session per attempt so we get a clean delegate stream.
            let streamingSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            dataTask = streamingSession.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }

                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let msg = "Ollama error (HTTP \(http.statusCode)). \(body)"
                    print("❌ \(msg)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onError?(msg)
                        self?.finishStreamingIfNeeded()
                    }
                    return
                }

                if let error {
                    // If we got a timeout, retry once automatically.
                    if self.isTimeoutError(error), attempt < 1 {
                        let backoffMs = 200
                        print("⏱️ Chat stream timed out. Retrying once after \(backoffMs)ms")
                        self.scheduleRetry(afterMs: backoffMs) { [weak self] in
                            guard let self else { return }
                            if self.isStreamingFinished { return }
                            startStreamAttempt(attempt + 1)
                        }
                        return
                    }

                    let msg = "Chat stream failed: \(error.localizedDescription)"
                    print("❌ \(msg)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onError?(msg)
                        self?.finishStreamingIfNeeded()
                    }
                    return
                }

                // If the connection ended without an explicit `done` chunk, still finish so UI recovers.
                DispatchQueue.main.async { [weak self] in
                    self?.finishStreamingIfNeeded()
                }
            }
            dataTask?.resume()
        }

        // Attempt 0
        startStreamAttempt(0)
    }

    private func scheduleFlush() {
        flushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushBuffer()
        }
        flushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval, execute: item)
    }

    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        let chunk = buffer
        buffer = ""
        streamedText += chunk
        onReceiveChunk?(chunk)
    }

    private func finishStreamingIfNeeded() {
        guard !isStreamingFinished else { return }
        isStreamingFinished = true

        flushWorkItem?.cancel()
        flushBuffer()

        dataTask?.cancel()
        dataTask = nil

        let completion = onComplete
        onComplete = nil
        onReceiveChunk = nil
        onError = nil
        completion?()
    }

    func cancelStreaming() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        buffer = ""
        isStreamingFinished = true

        dataTask?.cancel()
        dataTask = nil
        onReceiveChunk = nil
        onComplete = nil
        onError = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let raw = String(data: data, encoding: .utf8) else { return }

        let lines = raw.components(separatedBy: "\n")

        for line in lines {
            guard !line.isEmpty else { continue }
            guard let jsonData = line.data(using: .utf8) else { continue }

            guard let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                // Ollama might occasionally emit non-JSON (rare); ignore that line.
                continue
            }

            let done = dict["done"] as? Bool ?? false

            var content: String? = nil
            if let message = dict["message"] as? [String: Any],
               let c = message["content"] as? String {
                content = c
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                if let content = content, !content.isEmpty {
                    self.buffer += content
                    self.scheduleFlush()
                }

                if done {
                    self.finishStreamingIfNeeded()
                }
            }
        }
    }

    // MARK: - Ollama health check

    /// Quick smoke test for the configured Ollama chat model.
    /// - Sends a non-streaming `/api/chat` request and expects the model to reply with `OK`.
    /// - Useful for debugging connectivity/model issues from inside the app.
    func testOllamaChat(completion: @escaping (Result<String, Error>) -> Void) {
        let baseURL = "\(ConfigManager.shared.ollamaBaseURL)/api/chat"
        let model = ConfigManager.shared.ollamaChatModel
        guard let url = URL(string: baseURL) else {
            completion(.failure(URLError(.badURL)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = min(max(5.0, ConfigManager.shared.chatTimeout), 60.0)

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a helpful assistant."],
                ["role": "user", "content": "Reply with exactly: OK"],
            ],
            "stream": false,
            "options": [
                "temperature": 0.0,
                "num_predict": 16
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(URLError(.badServerResponse))) }
                return
            }
            guard (200...299).contains(http.statusCode) else {
                DispatchQueue.main.async {
                    completion(.failure(URLError(.badServerResponse)))
                }
                return
            }
            guard let data else {
                DispatchQueue.main.async { completion(.failure(URLError(.zeroByteResource))) }
                return
            }

            do {
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let message = obj?["message"] as? [String: Any]
                let content = (message?["content"] as? String) ?? ""
                DispatchQueue.main.async { completion(.success(content)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    // MARK: - Non-stream chat fallback

    /// Non-streaming chat request (fallback when streaming fails).
    func sendMessageOnce(
        messages chatMessages: [ChatMessage],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let baseURL = "\(ConfigManager.shared.ollamaBaseURL)/api/chat"
        let model = ConfigManager.shared.ollamaChatModel
        guard let url = URL(string: baseURL) else {
            completion(.failure(URLError(.badURL)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = min(max(5.0, ConfigManager.shared.chatTimeout), 60.0)

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]

        let limit = ConfigManager.shared.maxChatHistoryMessages
        let trimmedChatMessages: [ChatMessage] = chatMessages.count > limit ? Array(chatMessages.suffix(limit)) : chatMessages

        for msg in trimmedChatMessages {
            var content: String = msg.text
            if msg.context?.isEmpty == false {
                content += "\n<context>\(msg.context ?? "")\n</context>"
            }
            messages.append([
                "role": msg.isUser ? "user" : "assistant",
                "content": content
            ])
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false
        ]

        let options = ConfigManager.shared.ollamaOptionsDictionary(for: .chat)
        if !options.isEmpty {
            payload["options"] = options
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async { completion(.failure(NSError(domain: "Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: body.isEmpty ? "Bad server response" : body]))) }
                return
            }
            guard let data else {
                DispatchQueue.main.async { completion(.failure(URLError(.zeroByteResource))) }
                return
            }

            do {
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let message = obj?["message"] as? [String: Any]
                let content = (message?["content"] as? String) ?? ""
                DispatchQueue.main.async { completion(.success(content)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }
}
