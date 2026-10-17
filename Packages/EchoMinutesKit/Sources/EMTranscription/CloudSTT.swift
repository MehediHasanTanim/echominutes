import EMCore
import Foundation

/// An engine that transcribes a whole track in one go (cloud services, EM-162). Times are on the track timeline.
/// `TrackTranscriber` uses this instead of its own speech-region loop.
public protocol WholeTrackTranscriptionEngine: TranscriptionEngine {
    func transcribeTrack(url: URL, samples: [Float], options: STTOptions,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment]
}

/// HTTP for cloud speech services: retries 429 / 5xx / network errors with backoff, maps errors to
/// `TranscriptionError` (rejected = permanent, failed = retry later). Tests inject a stubbed URLSession.
public struct CloudHTTP: Sendable {
    public let session: URLSession
    public var retries: Int
    public var backoff: Double

    public init(session: URLSession, retries: Int = 3, backoff: Double = 2) {
        self.session = session; self.retries = retries; self.backoff = backoff
    }

    public static let shared: CloudHTTP = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 3 * 3600
        return CloudHTTP(session: URLSession(configuration: c))
    }()

    public enum Body: Sendable { case none, data(Data), file(URL) }

    public func send(_ request: URLRequest, body: Body = .none, service: String) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response): (Data, URLResponse)
                switch body {
                case .none: (data, response) = try await session.data(for: request)
                case .data(let d): (data, response) = try await session.upload(for: request, from: d)
                case .file(let u): (data, response) = try await session.upload(for: request, fromFile: u)
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) { return data }
                let detail = Self.message(data)
                switch code {
                case 401, 403:
                    throw TranscriptionError.cloudRejected("\(service) rejected the API key (\(code)). Check it in Settings ▸ Transcription.")
                case 400, 404, 413, 415, 422:
                    throw TranscriptionError.cloudRejected("\(service) refused the audio (\(code)): \(detail)")
                case 429, 500...599:
                    guard attempt < retries else { throw TranscriptionError.cloudFailed("\(service) is busy (\(code)): \(detail)") }
                    attempt += 1
                    Log.info(.stt, "\(service) returned \(code); retry \(attempt)/\(retries)")
                    try await Task.sleep(for: .seconds(pow(backoff, Double(attempt))))
                    continue
                default:
                    throw TranscriptionError.cloudFailed("\(service) error \(code): \(detail)")
                }
            } catch let e as TranscriptionError {
                throw e
            } catch is CancellationError {
                throw TranscriptionError.cancelled
            } catch let e as URLError where e.code == .cancelled {
                throw TranscriptionError.cancelled
            } catch {
                guard attempt < retries else { throw TranscriptionError.cloudFailed("\(service) unreachable: \(error.localizedDescription)") }
                attempt += 1
                Log.info(.stt, "\(service) request failed (\(error.localizedDescription)); retry \(attempt)/\(retries)")
                try await Task.sleep(for: .seconds(pow(backoff, Double(attempt))))
            }
        }
    }

    /// Error text from a JSON body ({"error": …}, {"err_msg": …}, {"message": …}) or the raw body.
    static func message(_ data: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for k in ["err_msg", "error", "message", "detail"] {
                if let s = o[k] as? String { return s }
                if let d = o[k] as? [String: Any], let s = d["message"] as? String { return s }
            }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

enum CloudKey {
    static func require(_ key: String?, _ service: String) throws -> String {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else {
            throw TranscriptionError.cloudRejected("No \(service) API key — add it in Settings ▸ Transcription.")
        }
        return k
    }
}

/// 16-bit PCM WAV from 16 kHz mono Float32 samples.
enum WAV {
    static func encode(_ samples: ArraySlice<Float>, rate: Int = 16_000) -> Data {
        var d = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * Float(Int16.max))
            u16(UInt16(bitPattern: v))
        }
        return d
    }
}

/// multipart/form-data builder.
struct Multipart {
    let boundary = "EchoMinutes-\(UUID().uuidString)"
    private(set) var body = Data()
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, mime: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    mutating func finish() -> Data { body.append(Data("--\(boundary)--\r\n".utf8)); return body }
}

func mimeType(_ url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "m4a", "mp4": "audio/mp4"
    case "wav": "audio/wav"
    case "mp3": "audio/mpeg"
    default: "application/octet-stream"
    }
}

// MARK: - Deepgram (EM-163)

/// Deepgram pre-recorded API, Nova-3 (supports Bengali `bn`): uploads the track file, utterances with timestamps.
public struct DeepgramEngine: WholeTrackTranscriptionEngine {
    public static let service = "Deepgram"
    public let model: String
    let apiKey: @Sendable () -> String?
    let http: CloudHTTP
    let baseURL: URL

    public init(model: String = "nova-3", apiKey: @escaping @Sendable () -> String?, http: CloudHTTP = .shared,
                baseURL: URL = URL(string: "https://api.deepgram.com")!) {
        self.model = model; self.apiKey = apiKey; self.http = http; self.baseURL = baseURL
    }

    public var identifier: String { "deepgram:\(model)" }

    public func prepare(status: @escaping @Sendable (EngineStatus) -> Void) async throws {
        _ = try CloudKey.require(apiKey(), Self.service)
        status(.ready)
    }

    public func transcribe(samples: [Float], options: STTOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        try await send(.data(WAV.encode(samples[...])), mime: "audio/wav", options: options, progress: progress)
    }

    public func transcribeTrack(url: URL, samples: [Float], options: STTOptions,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        try await send(.file(url), mime: mimeType(url), options: options, progress: progress)
    }

    func request(mime: String, options: STTOptions) throws -> URLRequest {
        var c = URLComponents(url: baseURL.appendingPathComponent("v1/listen"), resolvingAgainstBaseURL: false)!
        var q = [URLQueryItem(name: "model", value: model), URLQueryItem(name: "language", value: options.language),
                 URLQueryItem(name: "utterances", value: "true"), URLQueryItem(name: "smart_format", value: "true"),
                 URLQueryItem(name: "punctuate", value: "true")]
        if model.hasPrefix("nova-3") { q += options.vocabulary.prefix(100).map { URLQueryItem(name: "keyterm", value: $0) } }
        c.queryItems = q
        let key = try CloudKey.require(apiKey(), Self.service)
        var r = URLRequest(url: c.url!)
        r.httpMethod = "POST"
        r.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        r.setValue(mime, forHTTPHeaderField: "Content-Type")
        return r
    }

    private func send(_ body: CloudHTTP.Body, mime: String, options: STTOptions,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        progress(0.05)
        let data = try await http.send(try request(mime: mime, options: options), body: body, service: Self.service)
        progress(1)
        return try Self.parse(data)
    }

    struct Response: Decodable {
        struct Results: Decodable {
            struct Utterance: Decodable { var start: Double; var end: Double; var transcript: String }
            struct Channel: Decodable {
                struct Alt: Decodable { var transcript: String }
                var alternatives: [Alt]
            }
            var utterances: [Utterance]?
            var channels: [Channel]?
        }
        struct Metadata: Decodable { var duration: Double? }
        var results: Results
        var metadata: Metadata?
    }

    static func parse(_ data: Data) throws -> [RawSegment] {
        let r: Response
        do { r = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw TranscriptionError.cloudFailed("Deepgram: unexpected response") }
        if let u = r.results.utterances, !u.isEmpty {
            return u.filter { !$0.transcript.isEmpty }.map { RawSegment(start: $0.start, end: $0.end, text: $0.transcript) }
        }
        let text = r.results.channels?.first?.alternatives.first?.transcript ?? ""
        return text.isEmpty ? [] : [RawSegment(start: 0, end: r.metadata?.duration ?? 0, text: text)]
    }

    /// Checks a key without sending audio.
    public static func validate(key: String, http: CloudHTTP = .shared) async throws {
        var r = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
        r.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        _ = try await http.send(r, service: service)
    }
}

// MARK: - AssemblyAI (EM-164)

/// AssemblyAI: upload → transcript job → poll. `universal-3-pro` with `universal-2` fallback (Bengali is
/// Universal-2 only). The transcript is deleted from AssemblyAI after it's fetched.
public struct AssemblyAIEngine: WholeTrackTranscriptionEngine {
    public static let service = "AssemblyAI"
    let apiKey: @Sendable () -> String?
    let http: CloudHTTP
    let baseURL: URL
    let pollInterval: Double
    let maxWait: Double

    public init(apiKey: @escaping @Sendable () -> String?, http: CloudHTTP = .shared,
                baseURL: URL = URL(string: "https://api.assemblyai.com")!, pollInterval: Double = 3, maxWait: Double = 3 * 3600) {
        self.apiKey = apiKey; self.http = http; self.baseURL = baseURL; self.pollInterval = pollInterval; self.maxWait = maxWait
    }

    public var identifier: String { "assemblyai:universal" }

    public func prepare(status: @escaping @Sendable (EngineStatus) -> Void) async throws {
        _ = try CloudKey.require(apiKey(), Self.service)
        status(.ready)
    }

    public func transcribe(samples: [Float], options: STTOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        try await run(.data(WAV.encode(samples[...])), options: options, progress: progress)
    }

    public func transcribeTrack(url: URL, samples: [Float], options: STTOptions,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        try await run(.file(url), options: options, progress: progress)
    }

    private func req(_ path: String, method: String, json: [String: Any]? = nil) throws -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue(try CloudKey.require(apiKey(), Self.service), forHTTPHeaderField: "authorization")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    private func run(_ audio: CloudHTTP.Body, options: STTOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        progress(0.02)
        var up = try req("v2/upload", method: "POST")
        up.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let uploaded = try await http.send(up, body: audio, service: Self.service)
        guard let uploadURL = (try? JSONSerialization.jsonObject(with: uploaded) as? [String: Any])?["upload_url"] as? String else {
            throw TranscriptionError.cloudFailed("AssemblyAI: upload failed")
        }
        progress(0.2)

        var body: [String: Any] = ["audio_url": uploadURL, "speech_models": ["universal-3-pro", "universal-2"],
                                   "language_code": options.language]
        if !options.vocabulary.isEmpty { body["keyterms_prompt"] = Array(options.vocabulary.prefix(200)) }
        let created = try await http.send(try req("v2/transcript", method: "POST", json: body), service: Self.service)
        guard let id = (try? JSONSerialization.jsonObject(with: created) as? [String: Any])?["id"] as? String else {
            throw TranscriptionError.cloudFailed("AssemblyAI: couldn't create the transcript")
        }
        defer {
            // Privacy: don't leave the transcript on AssemblyAI's servers.
            let http = self.http
            if let del = try? req("v2/transcript/\(id)", method: "DELETE") {
                Task.detached { _ = try? await http.send(del, service: Self.service) }
            }
        }

        let started = Date()
        while true {
            try Task.checkCancellation()
            let data = try await http.send(try req("v2/transcript/\(id)", method: "GET"), service: Self.service)
            let t = try JSONDecoder().decode(Transcript.self, from: data)
            switch t.status {
            case "completed":
                progress(1)
                return Self.segments(fromWords: t.words ?? [], fallbackText: t.text)
            case "error":
                throw TranscriptionError.cloudRejected("AssemblyAI: \(t.error ?? "transcription failed")")
            default:
                let waited = Date().timeIntervalSince(started)
                if waited > maxWait { throw TranscriptionError.cloudFailed("AssemblyAI: timed out") }
                progress(min(0.95, 0.2 + waited / 600 * 0.75))
                try await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    struct Word: Decodable { var text: String; var start: Int; var end: Int }
    struct Transcript: Decodable { var status: String; var error: String?; var text: String?; var words: [Word]? }

    /// Words (ms) → segments: break on pauses > 1 s, after a sentence end once ≥ 2 s long, or at 15 s.
    static func segments(fromWords words: [Word], fallbackText: String? = nil) -> [RawSegment] {
        var out: [RawSegment] = []
        var cur: [Word] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            out.append(RawSegment(start: Double(f.start) / 1000, end: Double(l.end) / 1000,
                                  text: cur.map(\.text).joined(separator: " ")))
            cur = []
        }
        for w in words {
            if let f = cur.first, let l = cur.last {
                let length = l.end - f.start
                let sentenceEnd = l.text.last.map { ".?!।".contains($0) } ?? false
                if w.start - l.end > 1000 || (sentenceEnd && length >= 2000) || length >= 15000 { flush() }
            }
            cur.append(w)
        }
        flush()
        if out.isEmpty, let t = fallbackText, !t.isEmpty { out = [RawSegment(start: 0, end: 0, text: t)] }
        return out
    }

    public static func validate(key: String, http: CloudHTTP = .shared) async throws {
        var r = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript?limit=1")!)
        r.setValue(key, forHTTPHeaderField: "authorization")
        _ = try await http.send(r, service: service)
    }
}

// MARK: - OpenAI (EM-165)

/// OpenAI audio transcriptions. Uploads are limited to 25 MB, so speech is sent as WAV chunks of ≤ 10 min,
/// cut at pauses (speech regions packed together; long silences are skipped). `whisper-1` returns sentence
/// timestamps; the gpt-4o models return text only, so each chunk becomes one segment.
public struct OpenAITranscriptionEngine: WholeTrackTranscriptionEngine {
    public static let service = "OpenAI"
    public static let models = ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
    public static let maxChunkSeconds = 600.0
    public let model: String
    let apiKey: @Sendable () -> String?
    let http: CloudHTTP
    let baseURL: URL

    public init(model: String = "whisper-1", apiKey: @escaping @Sendable () -> String?, http: CloudHTTP = .shared,
                baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.model = model; self.apiKey = apiKey; self.http = http; self.baseURL = baseURL
    }

    public var identifier: String { "openai:\(model)" }
    var timestamps: Bool { model == "whisper-1" }

    public func prepare(status: @escaping @Sendable (EngineStatus) -> Void) async throws {
        _ = try CloudKey.require(apiKey(), Self.service)
        status(.ready)
    }

    public func transcribeTrack(url: URL, samples: [Float], options: STTOptions,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        let rate = AudioLoader.sampleRate
        let chunks = Self.chunks(SpeechRegionDetector.detect(samples, rate: rate), maxSamples: Int(Self.maxChunkSeconds * rate))
        var out: [RawSegment] = []
        for (i, c) in chunks.enumerated() {
            try Task.checkCancellation()
            let segs = try await transcribe(samples: Array(samples[c]), options: options) { _ in }
            out += segs.map { $0.shifted(by: Double(c.lowerBound) / rate) }
            progress(Double(i + 1) / Double(max(1, chunks.count)))
        }
        return out
    }

    /// Packs speech regions into sample ranges no longer than `maxSamples` (a long region is split).
    static func chunks(_ regions: [SpeechRegion], maxSamples: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var cur: Range<Int>?
        for r in regions {
            var start = r.start
            while r.end - start > maxSamples {                      // very long monologue
                if let c = cur { out.append(c); cur = nil }
                out.append(start..<start + maxSamples)
                start += maxSamples
            }
            let piece = start..<r.end
            if let c = cur, piece.upperBound - c.lowerBound <= maxSamples {
                cur = c.lowerBound..<piece.upperBound
            } else {
                if let c = cur { out.append(c) }
                cur = piece
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    public func transcribe(samples: [Float], options: STTOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        guard !samples.isEmpty else { return [] }
        var m = Multipart()
        m.field("model", model)
        m.field("language", options.language)
        if !options.vocabulary.isEmpty { m.field("prompt", options.vocabulary.joined(separator: ", ")) }
        m.field("response_format", timestamps ? "verbose_json" : "json")
        if timestamps { m.field("timestamp_granularities[]", "segment") }
        m.file("file", filename: "audio.wav", mime: "audio/wav", data: WAV.encode(samples[...]))
        let body = m.finish()
        let key = try CloudKey.require(apiKey(), Self.service)
        var r = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue(m.contentType, forHTTPHeaderField: "Content-Type")
        let data = try await http.send(r, body: .data(body), service: Self.service)
        progress(1)
        return try Self.parse(data, duration: Double(samples.count) / AudioLoader.sampleRate)
    }

    struct Verbose: Decodable {
        struct Segment: Decodable {
            var start: Double; var end: Double; var text: String
            var avg_logprob: Double?; var no_speech_prob: Double?; var compression_ratio: Double?; var temperature: Double?
        }
        var text: String?
        var segments: [Segment]?
    }

    static func parse(_ data: Data, duration: Double) throws -> [RawSegment] {
        guard let v = try? JSONDecoder().decode(Verbose.self, from: data) else {
            throw TranscriptionError.cloudFailed("OpenAI: unexpected response")
        }
        if let segs = v.segments {
            return segs.map {
                RawSegment(start: $0.start, end: $0.end, text: $0.text, avgLogprob: $0.avg_logprob ?? -0.3,
                           noSpeechProb: $0.no_speech_prob ?? 0.05, compressionRatio: $0.compression_ratio ?? 1.3,
                           temperature: $0.temperature ?? 0)
            }
        }
        let text = (v.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [RawSegment(start: 0, end: duration, text: text)]
    }
}
