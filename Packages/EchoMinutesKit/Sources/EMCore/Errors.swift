import Foundation

/// Errors shared across modules; user-facing text via `localizedDescription`.
public enum EMError: Error, Sendable, Equatable, LocalizedError {
    case permissionDenied(String)        // which permission
    case deviceUnavailable(String)
    case diskFull(availableBytes: Int64)
    case notFound(String)
    case invalidData(String)
    case provider(ProviderID, ProviderFailure)
    case cancelled

    public enum ProviderFailure: String, Sendable, Equatable { case invalidKey, rateLimited, quotaExceeded, network, server, badResponse }

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let p): return "EchoMinutes doesn't have \(p) permission."
        case .deviceUnavailable(let d): return "Audio device unavailable: \(d)."
        case .diskFull(let b): return "Not enough disk space (\(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)) free)."
        case .notFound(let what): return "\(what) not found."
        case .invalidData(let what): return "Invalid data: \(what)."
        case .cancelled: return "Cancelled."
        case .provider(let p, let f):
            let name = p.displayName
            switch f {
            case .invalidKey: return "\(name): the API key was rejected. Check it in Settings ▸ Providers."
            case .rateLimited: return "\(name) is rate-limiting requests. Will retry automatically."
            case .quotaExceeded: return "\(name): quota or credit exhausted."
            case .network: return "Couldn't reach \(name). Will retry when online."
            case .server: return "\(name) had a server error. Will retry."
            case .badResponse: return "\(name) returned an unexpected response."
            }
        }
    }
}
