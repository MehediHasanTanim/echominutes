import AppKit
import CoreAudio
import Foundation

/// EM-004 — Spike S1a: live list of Core Audio process objects with input/output state.
///
/// Usage: run.sh processes [--all] [--filter <text>] [--duration <sec>] [--quiet]
///   --all        table shows every audio process object, not only active ones
///   --filter     only show/log processes whose bundle ID, app or executable contains <text>
///   --duration   stop after N seconds (otherwise Ctrl+C in run.sh)
/// Every change is also appended to output/processes-<timestamp>.csv (input for EM-007 timelines).
enum ProcessesCommand {
    private static var current: AudioProcessMonitor?   // keep the monitor alive while listening

    static func run(_ args: [String]) async -> Int32 {
        var showAll = false, filter: String?, duration: Double?, quiet = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--all": showAll = true
            case "--quiet": quiet = true
            case "--filter": i += 1; filter = i < args.count ? args[i].lowercased() : nil
            case "--duration": i += 1; duration = i < args.count ? Double(args[i]) : nil
            default: Log.warn("Ignoring unknown option \(args[i])")
            }
            i += 1
        }
        let monitor = AudioProcessMonitor(showAll: showAll, filter: filter, quiet: quiet)
        current = monitor
        defer { current = nil }
        return await withCheckedContinuation { cont in
            monitor.start(duration: duration) { cont.resume(returning: $0) }
        }
    }
}

final class AudioProcessMonitor {
    struct Proc: Equatable {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let exe: String
        let appName: String
        let appBundleID: String
        var input: Bool
        var output: Bool
        var isSelf: Bool { pid == getpid() }
        var label: String { "\(bundleID.isEmpty ? "-" : bundleID) [\(appName)/\(exe)]" }
    }

    private let queue = DispatchQueue(label: "spikelab.processes")   // all state confined here
    private var procs: [AudioObjectID: Proc] = [:]
    private var listened = Set<AudioObjectID>()
    private let showAll: Bool
    private let filter: String?
    private var csv: FileHandle?
    private var csvPath = ""
    private var eventCount = 0
    private var pollCount = 0
    private var deviceEvents = 0
    private var tablePending = false
    private var onStop: ((Int32) -> Void)?
    private var signalSources: [DispatchSourceSignal] = []

    private let quiet: Bool   // CSV only (background logging), no table/event console output
    init(showAll: Bool, filter: String?, quiet: Bool = false) { self.showAll = showAll; self.filter = filter; self.quiet = quiet }

    func start(duration: Double?, onStop: @escaping (Int32) -> Void) {
        self.onStop = onStop
        openCSV()
        installSignalHandlers()
        queue.async {
            Log.line("Watching audio processes (Ctrl+C to stop)\(self.filter.map { ", filter='\($0)'" } ?? "")")
            Log.line("CSV: \(self.csvPath)")
            self.addListener(CA.system, kAudioHardwarePropertyProcessObjectList)
            self.addDeviceListeners()
            self.refreshProcessList(initial: true)
            self.printTable(reason: "initial snapshot")
            self.schedulePoll()
        }
        if let duration {
            queue.asyncAfter(deadline: .now() + duration) { self.stop(reason: "duration \(Int(duration))s elapsed") }
        }
    }

    // MARK: - Listeners

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var addr = CA.address(selector)
        let status = AudioObjectAddPropertyListenerBlock(object, &addr, queue) { [weak self] _, _ in
            self?.handleChange(object: object, selector: selector)
        }
        if status != noErr { Log.warn("Listener failed obj=\(object) sel=\(fourCC(selector)): \(describeStatus(status))") }
    }

    private func handleChange(object: AudioObjectID, selector: AudioObjectPropertySelector) {
        if object == CA.system {
            refreshProcessList(initial: false)
        } else if var p = procs[object] {
            let newIn = (CA.uint32(object, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
            let newOut = (CA.uint32(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            if newIn != p.input { record(newIn ? "input_on" : "input_off", p) }
            if newOut != p.output { record(newOut ? "output_on" : "output_off", p) }
            p.input = newIn; p.output = newOut
            procs[object] = p
        }
        scheduleTable()
    }

    /// Experiment (EM-004 finding): per-process IsRunningInput/Output listeners did not fire on macOS 26.6.
    /// Test whether device-level kAudioDevicePropertyDeviceIsRunningSomewhere fires, to use as a re-scan trigger.
    private func addDeviceListeners() {
        for dev in CA.objectIDs(CA.system, kAudioHardwarePropertyDevices) {
            let name = CA.string(dev, kAudioObjectPropertyName) ?? "device \(dev)"
            var addr = CA.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let status = AudioObjectAddPropertyListenerBlock(dev, &addr, queue) { [weak self] _, _ in
                guard let self else { return }
                let running = (CA.uint32(dev, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
                Log.line("⚡ device_running=\(running ? 1 : 0)  \(name) — listener fired, re-scanning processes")
                self.deviceEvents += 1
                self.rescanStates(source: "device")
            }
            if status != noErr { Log.warn("Device listener failed for \(name): \(describeStatus(status))") }
        }
    }

    /// Re-read all process states; `source` tags how the change was noticed (device listener vs poll).
    private func rescanStates(source: String) {
        for (id, var p) in procs {
            let newIn = (CA.uint32(id, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
            let newOut = (CA.uint32(id, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            guard newIn != p.input || newOut != p.output else { continue }
            let oldIn = p.input, oldOut = p.output
            p.input = newIn; p.output = newOut
            procs[id] = p
            if source == "poll" && !quiet { Log.warn("Change for pid \(p.pid) caught only by 1 s poll") }
            if newIn != oldIn { record((newIn ? "input_on_" : "input_off_") + source, p) }
            if newOut != oldOut { record((newOut ? "output_on_" : "output_off_") + source, p) }
            scheduleTable()
        }
    }

    /// Safety net: re-read every process once per second. If state changed without a listener
    /// callback, log it as `<event>_poll` so we can tell "no activity" from "listener didn't fire".
    private func schedulePoll() {
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.onStop != nil else { return }
            self.rescanStates(source: "poll")
            self.pollCount += 1
            self.schedulePoll()
        }
    }

    private func refreshProcessList(initial: Bool) {
        let ids = Set(CA.objectIDs(CA.system, kAudioHardwarePropertyProcessObjectList))
        for gone in Set(procs.keys).subtracting(ids) {
            if let p = procs.removeValue(forKey: gone) { record("process_removed", p) }
            listened.remove(gone)
        }
        for id in ids.subtracting(procs.keys) {
            guard let p = makeProc(id) else { continue }
            procs[id] = p
            if !initial { record("process_added", p) }
            else {
                if p.input { record("input_on", p, initial: true) }
                if p.output { record("output_on", p, initial: true) }
            }
            if !listened.contains(id) {
                addListener(id, kAudioProcessPropertyIsRunningInput)
                addListener(id, kAudioProcessPropertyIsRunningOutput)
                listened.insert(id)
            }
        }
    }

    private func makeProc(_ id: AudioObjectID) -> Proc? {
        guard let pid = CA.pid(id) else { return nil }
        let bundle = CA.string(id, kAudioProcessPropertyBundleID) ?? ""
        let path = ProcInfo.path(pid) ?? ""
        let exe = path.isEmpty ? (NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?") : (path as NSString).lastPathComponent
        let owner = ProcInfo.owningApp(forPath: path)
        return Proc(objectID: id, pid: pid, bundleID: bundle, exe: exe,
                    appName: owner?.name ?? exe, appBundleID: owner?.bundleID ?? "",
                    input: (CA.uint32(id, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                    output: (CA.uint32(id, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0)
    }

    private func matches(_ p: Proc) -> Bool {
        guard let filter else { return true }
        return [p.bundleID, p.appName, p.exe, p.appBundleID].contains { $0.lowercased().contains(filter) }
    }

    // MARK: - Output

    private func record(_ event: String, _ p: Proc, initial: Bool = false) {
        guard matches(p) else { return }
        eventCount += 1
        let base = event.replacingOccurrences(of: "_poll", with: "").replacingOccurrences(of: "_device", with: "")
        let icons = ["input_on": "🎙▲", "input_off": "🎙▼", "output_on": "🔊▲", "output_off": "🔊▼", "process_added": "＋ "]
        let icon = icons[base] ?? "－ "
        if !initial && !quiet { Log.line("\(icon) \(event.padding(toLength: 15, withPad: " ", startingAt: 0)) pid \(p.pid)\(p.isSelf ? " (SpikeLab)" : "")  \(p.label)") }
        let now = Date()
        let iso = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        let row = [iso, String(Int(now.timeIntervalSince1970 * 1000)), initial ? "\(event)_initial" : event, String(p.pid),
                   p.bundleID, p.appName, p.appBundleID, p.exe, p.input ? "1" : "0", p.output ? "1" : "0"]
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") + "\n"
        csv?.write(Data(row.utf8))
    }

    private func scheduleTable() {
        guard !tablePending else { return }
        tablePending = true
        queue.asyncAfter(deadline: .now() + 0.3) { self.tablePending = false; self.printTable(reason: "after change") }
    }

    private func printTable(reason: String) {
        if quiet { return }
        let rows = procs.values
            .filter { matches($0) && (showAll || $0.input || $0.output) }
            .sorted { ($0.input ? 0 : 1, $0.appName, $0.pid) < ($1.input ? 0 : 1, $1.appName, $1.pid) }
        print("\n┌─ \(showAll ? "all" : "active") audio processes (\(rows.count) of \(procs.count) objects) — \(reason)")
        let widths = [7, 4, 4, 22, 34, 0]
        func fmt(_ cols: [String]) -> String {
            "│ " + cols.enumerated().map { widths[$0] == 0 ? $1 : $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: " ")
        }
        print(fmt(["PID", "MIC", "OUT", "APP", "EXECUTABLE", "AUDIO BUNDLE ID"]))
        for p in rows {
            let cols = [String(p.pid), p.input ? "●" : "·", p.output ? "●" : "·",
                        String(p.appName.prefix(22)), String(p.exe.prefix(34)), p.bundleID + (p.isSelf ? "  ← SpikeLab" : "")]
            print(fmt(cols))
        }
        if rows.isEmpty { print("│ (none)") }
        print("└─")
    }

    // MARK: - Lifecycle

    private func openCSV() {
        // <repo>/spikes/SpikeLab/build/SpikeLab.app → <repo>/spikes/SpikeLab/output
        let outDir = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("output")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = outDir.appendingPathComponent("processes-\(f.string(from: Date())).csv")
        FileManager.default.createFile(atPath: url.path,
            contents: Data("timestamp,epoch_ms,event,pid,audio_bundle_id,app_name,app_bundle_id,executable,input,output\n".utf8))
        csv = FileHandle(forWritingAtPath: url.path)
        csv?.seekToEndOfFile()
        csvPath = url.path
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

    private func stop(reason: String) {
        guard let onStop else { return }
        self.onStop = nil
        printTable(reason: "final")
        Log.line("Stopped (\(reason)). \(eventCount) events, \(deviceEvents) device-listener callbacks, \(pollCount) polls. CSV: \(csvPath)")
        try? csv?.close()
        onStop(0)
    }
}

func fourCC(_ v: UInt32) -> String {
    let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
    return String(bytes: b, encoding: .ascii) ?? "\(v)"
}
