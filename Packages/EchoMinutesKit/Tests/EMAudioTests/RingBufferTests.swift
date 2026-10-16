import CoreAudio
import EMCore
import Foundation
import Testing
@testable import EMAudio

@Suite("SPSCRingBuffer")
struct RingBufferTests {
    @Test func capacityRoundsUpToPowerOfTwo() {
        #expect(SPSCRingBuffer(minimumCapacity: 1000).capacity == 1024)
        #expect(SPSCRingBuffer(minimumCapacity: 1024).capacity == 1024)
    }

    @Test func writeReadWrapAround() {
        let rb = SPSCRingBuffer(minimumCapacity: 8)
        for round in 0..<5 {                                   // forces wrap-around many times
            let input = (0..<6).map { Float(round * 10 + $0) }
            input.withUnsafeBufferPointer { _ = rb.write($0.baseAddress!, count: 6) }
            #expect(rb.availableToRead == 6)
            #expect(rb.read(maxCount: 100) == input)
            #expect(rb.availableToRead == 0)
        }
        #expect(rb.overruns == 0)
    }

    @Test func overrunDropsNewSamplesOnly() {
        let rb = SPSCRingBuffer(minimumCapacity: 4)
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        let written = input.withUnsafeBufferPointer { rb.write($0.baseAddress!, count: 6) }
        #expect(written == 4 && rb.overruns == 2)
        #expect(rb.read(maxCount: 10) == [1, 2, 3, 4])           // oldest kept, newest dropped
    }

    @Test func strideSelectsChannel() {
        let rb = SPSCRingBuffer(minimumCapacity: 16)
        let interleaved: [Float] = [1, -1, 2, -2, 3, -3]       // L,R pairs
        interleaved.withUnsafeBufferPointer { _ = rb.write($0.baseAddress!, count: 3, stride: 2) }
        #expect(rb.read(maxCount: 10) == [1, 2, 3])
    }

    @Test func downmixAveragesChannels() {
        let rb = SPSCRingBuffer(minimumCapacity: 16)
        let stereo: [Float] = [1, 0, 0.5, 0.5, -1, 1]
        stereo.withUnsafeBufferPointer { _ = rb.writeDownmix($0.baseAddress!, frames: 3, channels: 2) }
        #expect(rb.read(maxCount: 10) == [0.5, 0.5, 0])
    }

    @Test func silenceAndPreRollTrim() {
        let rb = SPSCRingBuffer(minimumCapacity: 32)
        let ramp = (0..<20).map(Float.init)
        ramp.withUnsafeBufferPointer { _ = rb.write($0.baseAddress!, count: 20) }
        #expect(rb.discardAllButLast(5) == 15)
        #expect(rb.read(maxCount: 10) == [15, 16, 17, 18, 19])
        rb.writeSilence(count: 3)
        #expect(rb.read(maxCount: 10) == [0, 0, 0])
        #expect(rb.discardAll() == 0)
        #expect(rb.totalWritten == 23)
    }

    /// Producer on one thread, consumer on another: values must arrive in order with no corruption.
    @Test func concurrentProducerConsumer() async {
        let rb = SPSCRingBuffer(minimumCapacity: 4096)
        let total = 2_000_000
        let producer = Task.detached {
            var next = 0
            var chunk = [Float](repeating: 0, count: 256)
            while next < total {
                let n = min(256, total - next)
                for i in 0..<n { chunk[i] = Float((next + i) % 1_000_000) }
                let w = chunk.withUnsafeBufferPointer { rb.write($0.baseAddress!, count: n) }
                next += w
                if w < n { await Task.yield() }       // full: let consumer catch up (overrun counted, value re-sent)
            }
        }
        let consumer = Task.detached { () -> (Int, Bool) in
            var received = 0, ordered = true
            var buf = [Float](repeating: 0, count: 1024)
            while received < total {
                let n = buf.withUnsafeMutableBufferPointer { rb.read(into: $0.baseAddress!, maxCount: 1024) }
                for i in 0..<n where buf[i] != Float((received + i) % 1_000_000) { ordered = false }
                received += n
                if n == 0 { await Task.yield() }
            }
            return (received, ordered)
        }
        await producer.value
        let (received, ordered) = await consumer.value
        #expect(received == total)
        #expect(ordered)
    }
}

@Suite("Process resolver")
struct ProcessResolverTests {
    let teams = DetectionRules.App(id: "teams", name: "Microsoft Teams", bundlePrefixes: ["com.microsoft.teams2"])
    let procs: [AudioProcessInfo] = [
        .init(objectID: 1, pid: 100, bundleID: "com.microsoft.teams2", owningAppBundleID: "com.microsoft.teams2", executable: "MSTeams"),
        .init(objectID: 2, pid: 101, bundleID: "com.microsoft.teams2.helper", owningAppBundleID: "com.microsoft.teams2", executable: "Microsoft Teams WebView Helper"),
        .init(objectID: 3, pid: 102, bundleID: "", owningAppBundleID: "com.microsoft.teams2", executable: "Unnamed helper"),   // no audio bundle ID
        .init(objectID: 4, pid: 200, bundleID: "us.zoom.xos", owningAppBundleID: "us.zoom.xos", executable: "zoom.us"),
        .init(objectID: 5, pid: 999, bundleID: "com.microsoft.teams2", owningAppBundleID: "", executable: "self"),
    ]

    @Test func resolvesAllAppProcessesIncludingHelpers() {
        let r = AudioProcesses.resolve(teams, in: procs, selfPID: 999)
        #expect(r.map(\.objectID) == [1, 2, 3])                 // helper with empty bundle ID found via owning app
    }

    @Test func excludesOwnProcessAndOtherApps() {
        let r = AudioProcesses.resolve(teams, in: procs, selfPID: 999)
        #expect(!r.contains { $0.pid == 999 || $0.pid == 200 })
    }

    @Test func emptyWhenAppNotRunning() {
        let whatsapp = DetectionRules.App(id: "whatsapp", name: "WhatsApp", bundlePrefixes: ["net.whatsapp.WhatsApp"])
        #expect(AudioProcesses.resolve(whatsapp, in: procs).isEmpty)
    }
}

@Suite("RecordingService")
struct RecordingServiceTests {
    @Test func dbConversion() {
        #expect(RecordingService.dB(1) == 0)
        #expect(RecordingService.dB(0) == -120)
        #expect(abs(RecordingService.dB(0.1) + 20) < 0.001)
    }

    @Test func startFailsCleanlyWhenAppHasNoProcesses() async {
        let svc = RecordingService()
        let ghost = DetectionRules.App(id: "ghost", name: "Ghost", bundlePrefixes: ["com.example.not-installed"])
        await #expect(throws: AudioCaptureError.self) { try await svc.start(app: ghost) }
        #expect(await svc.isRunning == false)
    }
}


@Suite("OutputRoute")
struct OutputRouteTests {
    @Test func classifiesEchoRisk() {
        let builtIn = kAudioDeviceTransportTypeBuiltIn
        #expect(OutputRoute(deviceName: "MacBook Pro Speakers", transportType: builtIn, dataSource: OutputRoute.fourCCSpeakers).isBuiltInSpeakers)
        #expect(!OutputRoute(deviceName: "External Headphones", transportType: builtIn, dataSource: OutputRoute.fourCCHeadphones).isBuiltInSpeakers)
        #expect(!OutputRoute(deviceName: "AirPods Pro", transportType: kAudioDeviceTransportTypeBluetooth, dataSource: nil).isBuiltInSpeakers)
        #expect(!OutputRoute(deviceName: "USB Headset", transportType: kAudioDeviceTransportTypeUSB, dataSource: nil).isBuiltInSpeakers)
        #expect(OutputRoute(deviceName: "LG UltraFine", transportType: kAudioDeviceTransportTypeDisplayPort, dataSource: nil).isBuiltInSpeakers)
    }
}
