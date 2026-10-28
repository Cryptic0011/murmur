enum DictationStage: Sendable, Equatable {
    case idle
    case recording
    case loadingModel
    case transcribing
    case cleaning(provider: String)
    /// `note`: a one-off remark shown with the result (cleanup fell back, length limit hit).
    case pasted(words: Int, note: String? = nil)
    case copiedOnly(message: String)
    case error(message: String)
}
