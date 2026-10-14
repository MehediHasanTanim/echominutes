import AVFoundation
import CoreAudio
import Foundation
import TapShim

/// EM-005 — Spike S1b: capture one app's audio output with a Core Audio process tap → WAV.
///
/// Usage: run.sh capture --app <text> [--duration <sec>]
///        run.sh capture --global [--duration <sec>]      (everything except SpikeLab)
///   --app   matches audio bundle ID, owning app bundle ID, app name or executable (case-insensitive),
///           e.g. teams | com.microsoft.teams2 | chrome | music | zoom | whatsapp
/// Output: spikes/SpikeLab/output/capture-<label>-<timestamp>.wav (32-bit float, tap's native rate/channels)
enum CaptureCommand {
    private static var current: ProcessTapRecorder?

    static func run(_ args: [String]) async -> Int32 {
        var needle: String?, global = false, duration: Double?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--app": i += 1; needle = i < args.count ? args[i].lowercased() : nil
            case "--global": global = true
            case "--duration": i += 1; duration = i < args.count ? Double(args[i]) : nil
            default: Log.warn("Ignoring unknown option \(args[i])")
            }
            i += 1
        }
        guard global || needle != nil else {
            Log.error("Specify --app <text> or --global"); return 2
        }
        guard #available(macOS 14.2, *) else { Log.error("Process taps need macOS 14.2+"); return 1 }

        let recorder = ProcessTapRecorder(needle: needle, global: global)
        current = recorder
        defer { current = nil }
        return await withCheckedContinuation { cont in
            recorder.start(duration: duration) { cont.resume(returning: $0) }
        }
    }
}

@available(macOS 14.2, *)
final class ProcessTapRecorder {
    struct Target { let objectID: AudioObjectID; let pid: pid_t; let bundleID: String; let appName: String; let exe: String }

    private let needle: String?
    private let global: Bool
    private let queue = DispatchQueue(label: "spikelab.capture", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var fileURL: URL?
    private var onStop: ((Int32) -> Void)?
    private var signalSources: [DispatchSourceSignal] = []

    // stats (touched only on `queue`)
    private var framesWritten: Int64 = 0
    private var overallPeak: Float = 0
    private var secondPeak: Float = 0
    private var secondFrames: Int64 = 0
    private var secondsTotal = 0
    private var secondsWithSignal = 0
    private var writeErrors = 0
    private var callbacks = 0          // IOProc invocations (total)
    private var emptyCallbacks = 0     // invocations that carried 0 bytes
    private var lastCallbacks = 0, lastEmpty = 0, lastFrames: Int64 = 0

    init(needle: String?, global: Bool) { self.needle = needle; self.global = global }

    // MARK: - Start

    func start(duration: Double?, onStop: @escaping (Int32) -> Void) {
        self.onStop = onStop
        installSignalHandlers()
        queue.async {
            do {
                try self.setUp()
                Log.line("Recording… (Ctrl+C to stop\(duration.map { ", or after \(Int($0)) s" } ?? ""))")
                Log.line("Level meter: one line per second (peak dBFS). Silence for the whole run usually means System Audio Recording permission is missing.")
            } catch {
                Log.error("\(error)")
                self.tearDown()
                self.finish(1)
                return
            }
            if let duration {
                self.queue.asyncAfter(deadline: .now() + duration) { self.stop(reason: "duration elapsed") }
            }
            self.heartbeat()
        }
    }

    private func setUp() throws {
        // 1. Resolve target process objects
        let selfObjects = allProcesses().filter { $0.pid == getpid() }.map(\.objectID)
        let desc: CATapDescription
        let label: String
        if global {
            desc = SLMakeGlobalTapExcluding(selfObjects.map { NSNumber(value: $0) })
            label = "global"
            Log.line("Target: all processes except SpikeLab")
        } else {
            let targets = allProcesses().filter { matches($0) && $0.pid != getpid() }
            guard !targets.isEmpty else {
                throw SpikeError("No audio process matches '\(needle ?? "")'. Is the app running? Try `run.sh processes --all`.")
            }
            Log.line("Target processes (\(targets.count)):")
            for t in targets { Log.line("   pid \(t.pid)  \(t.bundleID.isEmpty ? "-" : t.bundleID)  [\(t.appName)/\(t.exe)]") }
            desc = SLMakeMixdownTap(targets.map { NSNumber(value: $0.objectID) })
            label = targets.first!.appName.replacingOccurrences(of: " ", with: "")
        }
        desc.name = "SpikeLab capture"
        desc.isPrivate = true

        // 2. Create the tap
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { throw SpikeError("AudioHardwareCreateProcessTap: \(describeStatus(st))") }
        Log.ok("Tap created id=\(tapID)")

        // 3. Tap format
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = CA.address(kAudioTapPropertyFormat)
        st = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard st == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw SpikeError("Read tap format: \(describeStatus(st))")
        }
        format = fmt
        Log.ok("Tap format: \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch, interleaved=\(fmt.isInterleaved)")

        // 4. Private aggregate device: default output device as clock + our tap
        let outID = CA.defaultOutputDevice()
        guard let outUID = CA.string(outID, kAudioDevicePropertyDeviceUID) else { throw SpikeError("No default output device UID") }
        Log.line("Clock device: \(CA.string(outID, kAudioObjectPropertyName) ?? "?") (\(outUID))")
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpikeLab-Tap",
            kAudioAggregateDeviceUIDKey: "spikelab-tap-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard st == noErr else { throw SpikeError("AudioHardwareCreateAggregateDevice: \(describeStatus(st))") }
        Log.ok("Aggregate device id=\(aggregateID)")

        // 5. Output file
        let outDir = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let url = outDir.appendingPathComponent("capture-\(label)-\(df.string(from: Date())).wav")
        file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: fmt.isInterleaved)
        fileURL = url
        Log.line("File: \(url.path)")

        // 6. IO proc (delivered on our serial queue — fine for a spike, NOT real-time safe)
        st = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
        guard st == noErr, ioProcID != nil else { throw SpikeError("AudioDeviceCreateIOProcIDWithBlock: \(describeStatus(st))") }

        // 7. Start — first start triggers the "System Audio Recording" permission prompt
        st = AudioDeviceStart(aggregateID, ioProcID)
        guard st == noErr else { throw SpikeError("AudioDeviceStart: \(describeStatus(st))") }
        Log.ok("Capture started")
    }

    // MARK: - Audio

    private func handle(_ abl: UnsafePointer<AudioBufferList>) {
        callbacks += 1
        guard let format, let file else { return }
        // Peak across all float samples (format-agnostic for Float32)
        var peak: Float = 0
        var frames: Int64 = 0
        for buf in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl)) {
            guard let data = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let p = data.assumingMemoryBound(to: Float.self)
            for k in 0..<n { peak = max(peak, abs(p[k])) }
            frames = Int64(buf.mDataByteSize) / Int64(format.streamDescription.pointee.mBytesPerFrame)
        }
        if frames == 0 { emptyCallbacks += 1 }
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl, deallocator: nil) else { return }
        do { try file.write(from: pcm) } catch { writeErrors += 1 }
        framesWritten += frames
        overallPeak = max(overallPeak, peak)
        secondPeak = max(secondPeak, peak)
        secondFrames += frames
        if secondFrames >= Int64(format.sampleRate) {
            secondsTotal += 1
            let db = dBFS(secondPeak)
            if db > -60 { secondsWithSignal += 1 }
            let bars = max(0, min(40, Int((db + 60) / 1.5)))
            Log.line(String(format: "%4ds  %6.1f dBFS  ", secondsTotal, db) + String(repeating: "▮", count: bars))
            secondPeak = 0; secondFrames = 0
        }
    }

    /// Every 2 s: if no audio frames arrived, say whether the IOProc is running at all.
    private func heartbeat() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.onStop != nil else { return }
            let cb = self.callbacks - self.lastCallbacks, empty = self.emptyCallbacks - self.lastEmpty
            let fr = self.framesWritten - self.lastFrames
            if fr == 0 {
                Log.warn(cb == 0 ? "No IO callbacks in last 2 s — aggregate device not running"
                                 : "\(cb) IO callbacks, \(empty) empty, 0 audio frames — target app is not producing audio")
            }
            self.lastCallbacks = self.callbacks; self.lastEmpty = self.emptyCallbacks; self.lastFrames = self.framesWritten
            self.heartbeat()
        }
    }

    private func dBFS(_ x: Float) -> Float { x > 0 ? 20 * log10(x) : -120 }

    // MARK: - Stop

    private func stop(reason: String) {
        guard onStop != nil else { return }
        tearDown()
        let secs = format.map { Double(framesWritten) / $0.sampleRate } ?? 0
        Log.header("capture summary")
        Log.line("Stopped: \(reason)")
        Log.line(String(format: "Recorded %.1f s, overall peak %.1f dBFS, %d of %d seconds had signal (> -60 dBFS)",
                        secs, dBFS(overallPeak), secondsWithSignal, secondsTotal))
        Log.line("IO callbacks: \(callbacks) (\(emptyCallbacks) empty)")
        if writeErrors > 0 { Log.warn("\(writeErrors) buffer write errors") }
        if let fileURL { Log.line("WAV: \(fileURL.path)") }
        if secondsTotal > 0 && secondsWithSignal == 0 {
            Log.warn("Only silence captured. Check: the app was actually playing sound; System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording ▸ 'System Audio Recording Only' ▸ SpikeLab enabled")
            finish(1)
        } else {
            finish(0)
        }
    }

    private func tearDown() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
        file = nil   // closes the WAV (header finalized on deinit)
    }

    private func finish(_ code: Int32) {
        guard let onStop else { return }
        self.onStop = nil
        onStop(code)
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler { [weak self] in self?.stop(reason: "signal \(sig)") }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: - Process lookup

    private func allProcesses() -> [Target] {
        CA.objectIDs(CA.system, kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = CA.pid(id) else { return nil }
            let path = ProcInfo.path(pid) ?? ""
            let owner = ProcInfo.owningApp(forPath: path)
            let exe = (path as NSString).lastPathComponent
            return Target(objectID: id, pid: pid, bundleID: CA.string(id, kAudioProcessPropertyBundleID) ?? "",
                          appName: owner?.name ?? exe, exe: exe)
        }
    }

    private func matches(_ t: Target) -> Bool {
        guard let needle else { return false }
        let owner = ProcInfo.owningApp(forPath: ProcInfo.path(t.pid) ?? "")?.bundleID ?? ""
        return [t.bundleID, owner, t.appName, t.exe].contains { $0.lowercased().contains(needle) }
    }
}

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
