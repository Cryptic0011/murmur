enum DictationStage: Sendable, Equatable {
    case idle
    case recording
    case loadingModel
    case transcribing
    case cleaning(provider: String)
    case pasted(words: Int)
    case copiedOnly(message: String)
    case error(message: String)
}
