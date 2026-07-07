import Foundation

struct OpenAICompatibleChatClient: Sendable {
    struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    enum ClientError: Error {
        case badStatus(Int, message: String?)
        case decodeFailed
    }

    let endpoint: URL
    let bearerToken: String?
    let session: URLSession

    func cleanupRequest(
        model: String,
        temperature: Double,
        messages: [Message],
        maxCompletionTokens: Int? = nil
    ) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken, !bearerToken.isEmpty {
            req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        struct OpenAIBody: Encodable {
            let model: String
            let temperature: Double
            let messages: [Message]
            let maxCompletionTokens: Int?

            enum CodingKeys: String, CodingKey {
                case model, temperature, messages
                case maxCompletionTokens = "max_completion_tokens"
            }
        }
        let body = OpenAIBody(
            model: model,
            temperature: temperature,
            messages: messages,
            maxCompletionTokens: maxCompletionTokens
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

        struct Choice: Decodable { let message: Msg; struct Msg: Decodable { let content: String } }
        struct Wire: Decodable { let choices: [Choice] }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard let content = wire.choices.first?.message.content else { throw ClientError.decodeFailed }
        return content
    }
}
