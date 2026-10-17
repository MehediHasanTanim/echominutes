import Atomics
import CoreAudio
import EMCore
import EMTapShim
import Foundation

public enum AudioCaptureError: Error, Equatable, Sendable, LocalizedError {
    case noTargetProcesses(String)
    case tap(String), aggregate(String), ioProc(String), start(String), noDevice(String)
    public var errorDescription: String? {
        switch self {
        case .noTargetProcesses(let app): "\(app) isn't producing audio processes right now (is it running?)."
        case .tap(let s): "Couldn't create the system-audio tap (\(s))."
        case .aggregate(let s): "Couldn't create the capture device (\(s))."
        case .ioProc(let s), .start(let s): "Couldn't start audio capture (\(s))."
        case .noDevice(let s): "No \(s) device available."
        }
    }
}

/// Captures one app's output (process tap) and the microphone in ONE private aggregate device, so both tracks
/// share a clock and stay sample-aligned (Technical Design §7, decision from spike EM-016).
///
/// The IO block runs on Core Audio's real-time thread and only copies samples into two `SPSCRingBuffer`s:
/// `systemRing` (tap, downmixed to mono) and `micRing` (mic channel 0). Both always receive the same number of
/// frames per callback (silence fills a missing side) so they stay aligned.
public final class AggregateCapture: @unchecked Sendable {
    public let micRing: SPSCRingBuffer
    public let systemRing: SPSCRingBuffer
    public let includesMic: Bool
    public let processObjectIDs: [AudioObjectID]

    private let currentRate = ManagedAtomic<Int>(0)
    private let callbackCounter = ManagedAtomic<Int>(0)
    private let listenerQueue = DispatchQueue(label: "echominutes.capture.listener")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var rateListener: AudioObjectPropertyListenerBlock?
    public private(set) var deviceSummary = ""

    /// - Parameter bufferSeconds: ring capacity per track at 48 kHz (also the maximum pre-roll).
    public init(processObjectIDs: [AudioObjectID], includeMic: Bool, bufferSeconds: Double = 60) {
        self.processObjectIDs = processObjectIDs
        self.includesMic = includeMic
        let samples = Int(48_000 * bufferSeconds)
        systemRing = SPSCRingBuffer(minimumCapacity: samples)
        micRing = SPSCRingBuffer(minimumCapacity: samples)
    }

    deinit { stop() }

    /// Current aggregate sample rate (changes e.g. 48 k → 16 k when a Bluetooth headset enters call mode).
    public var sampleRate: Double { Double(currentRate.load(ordering: .relaxed)) }
    public var callbacks: Int { callbackCounter.load(ordering: .relaxed) }
    public var isRunning: Bool { ioProcID != nil }

    public func start() throws {
        guard !processObjectIDs.isEmpty else { throw AudioCaptureError.noTargetProcesses("Target app") }
        do { try setUp() } catch { stop(); throw error }
    }

    private func setUp() throws {
        // 1. Tap
        let desc = EMMakeMixdownTap(processObjectIDs.map { NSNumber(value: $0) })
        desc.name = "EchoMinutes capture"
        desc.isPrivate = true
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { throw AudioCaptureError.tap(CA.describe(st)) }

        // 2. Aggregate: default output (clock) [+ default input] + tap
        let outID = CA.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        guard let outUID = CA.string(outID, kAudioDevicePropertyDeviceUID) else { throw AudioCaptureError.noDevice("output") }
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: outUID]]
        var summary = "clock: \(CA.string(outID, kAudioObjectPropertyName) ?? outUID)"
        if includesMic {
            // Chosen mic (Settings ▸ Recording); falls back to the system default if it's unplugged.
            let chosen = RecordingPreferences.micDeviceUID.flatMap { AudioDevices.inputDevice(uid: $0) }
            if RecordingPreferences.micDeviceUID != nil, chosen == nil { Log.info(.audio, "Chosen microphone not connected — using system default") }
            let inID = chosen ?? CA.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
            guard let inUID = CA.string(inID, kAudioDevicePropertyDeviceUID) else { throw AudioCaptureError.noDevice("microphone") }
            if inUID != outUID { subDevices.append([kAudioSubDeviceUIDKey: inUID, kAudioSubDeviceDriftCompensationKey: true]) }
            summary += ", mic: \(CA.string(inID, kAudioObjectPropertyName) ?? inUID) @ \(Int(CA.nominalRate(inID))) Hz"
        }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EchoMinutes-Capture",
            kAudioAggregateDeviceUIDKey: "echominutes-capture-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard st == noErr else { throw AudioCaptureError.aggregate(CA.describe(st)) }
        currentRate.store(Int(CA.nominalRate(aggregateID)), ordering: .relaxed)
        deviceSummary = summary + ", streams \(CA.streamChannels(aggregateID, scope: kAudioObjectPropertyScopeInput))"
        Log.info(.audio, "Aggregate \(aggregateID) created: \(deviceSummary), rate \(Int(sampleRate)) Hz")

        // 3. Follow sample-rate changes (Bluetooth HFP switch, EM-016 finding)
        var rateAddr = CA.address(kAudioDevicePropertyNominalSampleRate)
        let agg = aggregateID, rate = currentRate
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            let r = Int(CA.nominalRate(agg))
            if r > 0, rate.exchange(r, ordering: .relaxed) != r { Log.info(.audio, "Capture sample rate → \(r) Hz") }
        }
        AudioObjectAddPropertyListenerBlock(aggregateID, &rateAddr, listenerQueue, listener)
        rateListener = listener

        // 4. Real-time IO block: copy only.
        let mic = micRing, sys = systemRing, withMic = includesMic, counter = callbackCounter
        let block: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            counter.wrappingIncrement(ordering: .relaxed)
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard list.count > 0 else { return }
            let tap = list[list.count - 1]
            let tapCh = max(Int(tap.mNumberChannels), 1)
            let tapFrames = Int(tap.mDataByteSize) / MemoryLayout<Float>.size / tapCh
            var micFrames = 0, micCh = 1
            var micData: UnsafeMutableRawPointer?
            if withMic, list.count >= 2 {
                micCh = max(Int(list[0].mNumberChannels), 1)
                micFrames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size / micCh
                micData = list[0].mData
            }
            let frames = max(tapFrames, micFrames)
            guard frames > 0 else { return }

            if let d = tap.mData, tapFrames > 0 {
                sys.writeDownmix(d.assumingMemoryBound(to: Float.self), frames: tapFrames, channels: tapCh)
                if tapFrames < frames { sys.writeSilence(count: frames - tapFrames) }
            } else { sys.writeSilence(count: frames) }

            if withMic {
                if let d = micData, micFrames > 0 {
                    mic.write(d.assumingMemoryBound(to: Float.self), count: micFrames, stride: micCh)
                    if micFrames < frames { mic.writeSilence(count: frames - micFrames) }
                } else { mic.writeSilence(count: frames) }
            }
        }
        var procID: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, block)
        guard st == noErr, let procID else { throw AudioCaptureError.ioProc(CA.describe(st)) }
        ioProcID = procID

        // 5. Start (first start triggers the System Audio Recording permission prompt)
        st = AudioDeviceStart(aggregateID, procID)
        guard st == noErr else { throw AudioCaptureError.start(CA.describe(st)) }
        Log.info(.audio, "Capture started for \(processObjectIDs.count) process object(s), mic=\(includesMic)")
    }

    /// Idempotent teardown in reverse order.
    public func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            if let rateListener {
                var addr = CA.address(kAudioDevicePropertyNominalSampleRate)
                AudioObjectRemovePropertyListenerBlock(aggregateID, &addr, listenerQueue, rateListener)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        rateListener = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
