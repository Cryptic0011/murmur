import Foundation

struct OpenAICompatibleChatClient: Sendable {
    struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    enum ClientError: Error {
        case badStatus(Int, message: String?)
        case decodeFailed
        /// The model hit its token limit mid-output (finish_reason "length").
        case truncated
    }

    let endpoint: URL
    let bearerToken: String?
    let session: URLSession

    func cleanupRequest(
        model: String,
        temperature: Double,
        messages: [Message],
        maxCompletionTokens: Int? = nil,
        reasoningEffort: String? = nil,
        includeReasoning: Bool? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        if let timeout { req.timeoutInterval = timeout }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken, !bearerToken.isEmpty {
            req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        struct OpenAIBody: Encodable {
            let model: String
            let temperature: Double
            let messages: [Message]
            let maxCompletionTokens: Int?
            let reasoningEffort: String?
            let includeReasoning: Bool?

            enum CodingKeys: String, CodingKey {
                case model, temperature, messages
                case maxCompletionTokens = "max_completion_tokens"
                case reasoningEffort = "reasoning_effort"
                case includeReasoning = "include_reasoning"
            }
        }
        let body = OpenAIBody(
            model: model,
            temperature: temperature,
            messages: messages,
            maxCompletionTokens: maxCompletionTokens,
            reasoningEffort: reasoningEffort,
            includeReasoning: includeReasoning
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badStatus(0, message: nil) }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorWire: Decodable {
                struct Inner: Decodable { let message: String? }
                let error: Inner?
            }
            let message = (try? JSONDecoder().decode(ErrorWire.self, from: data))?.error?.message
            throw ClientError.badStatus(http.statusCode, message: message)
        }

        struct Choice: Decodable {
            struct Msg: Decodable { let content: String? } // null when reasoning ate the whole budget
            let message: Msg?
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        struct Wire: Decodable { let choices: [Choice] }
        guard let choice = (try? JSONDecoder().decode(Wire.self, from: data))?.choices.first else {
            throw ClientError.decodeFailed
        }
        // A cut-off cleanup would paste the start of the dictation and silently drop the rest.
        if choice.finishReason == "length" { throw ClientError.truncated }
        guard let content = choice.message?.content, !content.isEmpty else { throw ClientError.decodeFailed }
        return content
    }
}
