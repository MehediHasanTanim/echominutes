import EMCore
import Foundation

/// What detection needs from the recorder (EM-070). `ManualRecorder` conforms; tests use a fake.
public protocol RecorderControl: Sendable {
    var state: ManualRecorder.State { get async }
    func startCandidate(app: DetectionRules.App, includeMic: Bool, preRoll: TimeInterval, now: Date) async throws
    func commitCandidate(now: Date) async throws -> Session
    func cancelCandidate() async
    func start(app: DetectionRules.App, includeMic: Bool, origin: ManualRecorder.Origin, now: Date) async throws -> Session
    func stop(now: Date) async throws -> Session
    func discard() async throws
}

extension ManualRecorder: RecorderControl {}
