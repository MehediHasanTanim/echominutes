import EMCore
import Foundation
import Testing
@testable import EMTranscription

/// Canned HTTP responses for the cloud engines (no network).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var body: String }
    nonisolated(unsafe) static var handler: (URLRequest) -> Reply = { _ in Reply(status: 500, body: "") }
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ h: @escaping (URLRequest) -> Reply) { lock.withLock { handler = h; requests = [] } }
    static var seen: [URLRequest] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { () -> Reply in Self.requests.append(request); return Self.handler(request) }
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func stubHTTP() -> CloudHTTP {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [StubURLProtocol.self]
    return CloudHTTP(session: URLSession(configuration: c), retries: 2, backoff: 0.01)
}

func tempAudioFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stt-\(UUID().uuidString).m4a")
    try Data(repeating: 1, count: 1_000).write(to: url)
    return url
}

/// 3 s of "speech" (a tone loud enough for the speech detector).
let speech: [Float] = (0..<48_000).map { Float(sin(Double($0) * 0.05)) * 0.3 }
let base = URL(string: "https://stub.test")!

@Suite("Cloud transcription", .serialized)
struct CloudSTTTests {
    @Test func deepgramSendsTheTrackAndParsesUtterances() async throws {
        StubURLProtocol.reset { _ in
            .init(status: 200, body: """
            {"metadata":{"duration":9.5},"results":{"channels":[{"alternatives":[{"transcript":"hello there how are you"}]}],
             "utterances":[{"start":0.5,"end":2.0,"transcript":"Hello there.","confidence":0.9},
                           {"start":3.1,"end":4.2,"transcript":"How are you?","confidence":0.8}]}}
            """)
        }
        let file = try tempAudioFile(); defer { try? FileManager.default.removeItem(at: file) }
        let e = DeepgramEngine(apiKey: { "dg-key" }, http: stubHTTP(), baseURL: base)
        let segs = try await e.transcribeTrack(url: file, samples: speech,
                                               options: STTOptions(language: "bn", vocabulary: ["EchoMinutes"])) { _ in }
        #expect(segs.map(\.text) == ["Hello there.", "How are you?"])
        #expect(segs.first?.start == 0.5)
        let req = try #require(StubURLProtocol.seen.first)
        #expect(req.url?.path == "/v1/listen")
        let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(q.contains(.init(name: "model", value: "nova-3")))
        #expect(q.contains(.init(name: "language", value: "bn")))
        #expect(q.contains(.init(name: "keyterm", value: "EchoMinutes")))
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Token dg-key")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
    }

    @Test func rejectedKeyIsPermanent() async throws {
        StubURLProtocol.reset { _ in .init(status: 401, body: #"{"err_msg":"Invalid credentials."}"#) }
        let file = try tempAudioFile(); defer { try? FileManager.default.removeItem(at: file) }
        let e = DeepgramEngine(apiKey: { "bad" }, http: stubHTTP(), baseURL: base)
        do {
            _ = try await e.transcribeTrack(url: file, samples: speech, options: STTOptions(language: "en")) { _ in }
            Issue.record("expected a rejection")
        } catch TranscriptionError.cloudRejected {
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(StubURLProtocol.seen.count == 1)                 // no retries on a bad key
    }

    @Test func busyServiceIsRetried() async throws {
        var calls = 0
        StubURLProtocol.reset { _ in
            calls += 1
            return calls < 2 ? .init(status: 503, body: "busy")
                             : .init(status: 200, body: #"{"results":{"utterances":[{"start":0,"end":1,"transcript":"ok"}]}}"#)
        }
        let file = try tempAudioFile(); defer { try? FileManager.default.removeItem(at: file) }
        let segs = try await DeepgramEngine(apiKey: { "k" }, http: stubHTTP(), baseURL: base)
            .transcribeTrack(url: file, samples: speech, options: STTOptions(language: "en")) { _ in }
        #expect(segs.map(\.text) == ["ok"])
        #expect(StubURLProtocol.seen.count == 2)
    }

    @Test func missingKeyFailsBeforeUploading() async throws {
        let e = AssemblyAIEngine(apiKey: { nil }, http: stubHTTP(), baseURL: base)
        await #expect(throws: TranscriptionError.self) { try await e.prepare { _ in } }
    }

    @Test func assemblyAIUploadCreatePollDelete() async throws {
        var polls = 0
        StubURLProtocol.reset { r in
            switch (r.httpMethod ?? "GET", r.url?.path ?? "") {
            case ("POST", "/v2/upload"): return .init(status: 200, body: #"{"upload_url":"https://cdn.test/a"}"#)
            case ("POST", "/v2/transcript"): return .init(status: 200, body: #"{"id":"t1","status":"queued"}"#)
            case ("GET", "/v2/transcript/t1"):
                polls += 1
                if polls < 2 { return .init(status: 200, body: #"{"status":"processing"}"#) }
                return .init(status: 200, body: """
                {"status":"completed","text":"Hi. Yes.","words":[
                 {"text":"Hi.","start":100,"end":400},{"text":"Yes.","start":3000,"end":3300}]}
                """)
            default: return .init(status: 200, body: "{}")
            }
        }
        let file = try tempAudioFile(); defer { try? FileManager.default.removeItem(at: file) }
        let e = AssemblyAIEngine(apiKey: { "aai" }, http: stubHTTP(), baseURL: base, pollInterval: 0.01)
        let segs = try await e.transcribeTrack(url: file, samples: speech, options: STTOptions(language: "bn")) { _ in }
        #expect(segs.map(\.text) == ["Hi.", "Yes."])                  // 2.6 s pause → two segments
        #expect(segs[1].start == 3.0)
        let create = try #require(StubURLProtocol.seen.first { $0.url?.path == "/v2/transcript" && $0.httpMethod == "POST" })
        #expect(create.value(forHTTPHeaderField: "authorization") == "aai")
        try await Task.sleep(for: .milliseconds(100))
        #expect(StubURLProtocol.seen.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/v2/transcript/t1" })
    }

    @Test func assemblyAIErrorIsPermanent() async throws {
        StubURLProtocol.reset { r in
            switch (r.httpMethod ?? "GET", r.url?.path ?? "") {
            case ("POST", "/v2/upload"): .init(status: 200, body: #"{"upload_url":"u"}"#)
            case ("POST", "/v2/transcript"): .init(status: 200, body: #"{"id":"t2"}"#)
            default: .init(status: 200, body: #"{"status":"error","error":"language not supported"}"#)
            }
        }
        let file = try tempAudioFile(); defer { try? FileManager.default.removeItem(at: file) }
        let e = AssemblyAIEngine(apiKey: { "aai" }, http: stubHTTP(), baseURL: base, pollInterval: 0.01)
        await #expect(throws: TranscriptionError.cloudRejected("AssemblyAI: language not supported")) {
            _ = try await e.transcribeTrack(url: file, samples: speech, options: STTOptions(language: "xx")) { _ in }
        }
    }

    @Test func openAIWhisperSegments() async throws {
        StubURLProtocol.reset { _ in
            .init(status: 200, body: """
            {"text":"a b","segments":[{"start":0.0,"end":1.2,"text":" first","avg_logprob":-0.2,"no_speech_prob":0.01,"compression_ratio":1.1,"temperature":0},
                                      {"start":1.5,"end":2.8,"text":" second","avg_logprob":-0.3,"no_speech_prob":0.02,"compression_ratio":1.2,"temperature":0}]}
            """)
        }
        let file = try tempAudioFile(); defer { try? FileManager.default.removeItem(at: file) }
        let e = OpenAITranscriptionEngine(apiKey: { "sk" }, http: stubHTTP(), baseURL: base)
        let segs = try await e.transcribeTrack(url: file, samples: speech, options: STTOptions(language: "en")) { _ in }
        #expect(segs.map { $0.text.trimmingCharacters(in: .whitespaces) } == ["first", "second"])
        let req = try #require(StubURLProtocol.seen.first)
        #expect(req.url?.path == "/audio/transcriptions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk")
        #expect(req.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
    }

    @Test func openAITextOnlyModelGivesOneSegmentPerChunk() throws {
        let segs = try OpenAITranscriptionEngine.parse(Data(#"{"text":"Hello everyone"}"#.utf8), duration: 42)
        #expect(segs == [RawSegment(start: 0, end: 42, text: "Hello everyone")])
    }
}

@Suite("Cloud transcription helpers")
struct CloudHelperTests {
    @Test func openAIChunksStayUnderTheLimitAndSkipSilence() {
        let r = { (a: Int, b: Int) in SpeechRegion(start: a, end: b) }
        let chunks = OpenAITranscriptionEngine.chunks([r(0, 100), r(150, 300), r(900, 1000), r(1100, 2500)], maxSamples: 500)
        #expect(chunks == [0..<300, 900..<1000, 1100..<1600, 1600..<2100, 2100..<2500])
        #expect(chunks.allSatisfy { $0.count <= 500 })
    }

    @Test func wordsBecomeSentences() {
        typealias W = AssemblyAIEngine.Word
        let words = [W(text: "We", start: 0, end: 200), W(text: "ship", start: 250, end: 500), W(text: "Friday.", start: 550, end: 2_100),
                     W(text: "Agreed", start: 2_200, end: 2_600)]
        let segs = AssemblyAIEngine.segments(fromWords: words)
        #expect(segs.map(\.text) == ["We ship Friday.", "Agreed"])
        #expect(segs[0].end == 2.1)
    }

    @Test func wavHeader() {
        let d = WAV.encode(([0, 0.5, -0.5, 1] as [Float])[...])
        #expect(d.count == 44 + 8)
        #expect(String(decoding: d.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: d[8..<12], as: UTF8.self) == "WAVE")
    }

    @Test func enginePerAppAndLocalOnly() {
        let s = TranscriptionSettings(model: "small", engine: .deepgram, appEngines: ["whatsapp": .assemblyAI, "teams": .local],
                                      openAIModel: "gpt-4o-transcribe")
        #expect(s.engine(forApp: "zoom", localOnly: false) == .deepgram)
        #expect(s.engine(forApp: "whatsapp", localOnly: false) == .assemblyAI)
        #expect(s.engine(forApp: "teams", localOnly: false) == .local)
        #expect(s.engine(forApp: "whatsapp", localOnly: true) == .local)        // "Local only" always wins
        #expect(s.engineKey(.local) == "small")
        #expect(s.engineKey(.openAI) == "openai:gpt-4o-transcribe")
        #expect(STTEngineChoice.from(identifier: "deepgram:nova-3") == .deepgram)
        #expect(STTEngineChoice.from(identifier: "whisperkit:small") == .local)
    }

    @Test func silentTrackIsNotUploaded() async throws {
        final class Counting: WholeTrackTranscriptionEngine, @unchecked Sendable {
            var calls = 0
            var identifier: String { "count" }
            func prepare(status: @escaping @Sendable (EngineStatus) -> Void) async throws {}
            func transcribe(samples: [Float], options: STTOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] { [] }
            func transcribeTrack(url: URL, samples: [Float], options: STTOptions,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] { calls += 1; return [] }
        }
        let e = Counting()
        let out = try await TrackTranscriber(engine: e).transcribe(url: URL(fileURLWithPath: "/dev/null"),
                                                                   samples: [Float](repeating: 0, count: 160_000),
                                                                   options: STTOptions(language: "en")) { _ in }
        #expect(e.calls == 0)
        #expect(out.segments.isEmpty)
    }
}
