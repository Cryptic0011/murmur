import Foundation

struct OpenAICompatibleChatClient: Sendable {
    struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    enum ClientError: Error {
        case badStatus(Int)
        case decodeFailed
    }

    let endpoint: URL
    let bearerToken: String?
    let session: URLSession

    func cleanupRequest(
        model: String,
        temperature: Double,
        messages: [Message],
        extraOptions: [String: Double] = [:]
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
        }
        let body = OpenAIBody(model: model, temperature: temperature, messages: messages)
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badStatus(0) }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.badStatus(http.statusCode) }

        struct Choice: Decodable { let message: Msg; struct Msg: Decodable { let content: String } }
        struct Wire: Decodable { let choices: [Choice] }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard let content = wire.choices.first?.message.content else { throw ClientError.decodeFailed }
        return content
    }
}
