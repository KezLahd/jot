import Foundation

/// Every failure carries a plain sentence that the list can show as the reason, with a retry.
public enum JotError: Error, LocalizedError, Equatable {
    case missingTool(String)
    case missingModel(String)
    case needsLogin(site: String)
    case unavailable(String)
    case fetchFailed(String)
    case noAudio
    case decodeFailed(String)
    case transcribeFailed(String)
    case speechUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingTool(let name): "\(name) isn't installed yet. Run `jot setup`."
        case .missingModel(let name): "The \(name) model isn't downloaded yet. Run `jot setup`."
        case .needsLogin(let site): "\(site) wanted a login for this one. Share the video instead."
        case .unavailable(let why): "This post isn't available: \(why)"
        case .fetchFailed(let why): "Couldn't fetch this link: \(why)"
        case .noAudio: "There's no sound in this one to transcribe."
        case .decodeFailed(let why): "Couldn't read the audio: \(why)"
        case .transcribeFailed(let why): "Transcription failed: \(why)"
        case .speechUnavailable: "On-device speech isn't available here, so your Mac will transcribe it."
        }
    }
}
