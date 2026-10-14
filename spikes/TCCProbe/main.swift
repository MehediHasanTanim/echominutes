// EM-002 TCC persistence probe.
// A tiny menu-less app that reports (and if needed requests) microphone permission,
// appends one line to a log file, then quits. Rebuilding with the same signing identity
// must NOT trigger a second permission prompt.
import AppKit
import AVFoundation

func describe(_ s: AVAuthorizationStatus) -> String {
    switch s {
    case .authorized: "authorized"
    case .denied: "denied"
    case .restricted: "restricted"
    case .notDetermined: "notDetermined"
    @unknown default: "unknown"
    }
}

let logPath = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) ?? "/tmp/tccprobe.log"

func finish(_ line: String) -> Never {
    let stamped = "\(ISO8601DateFormatter().string(from: Date())) build=\(buildStamp) \(line)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(Data(stamped.utf8)); try? h.close()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(stamped.utf8))
    }
    print(stamped, terminator: "")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let before = AVCaptureDevice.authorizationStatus(for: .audio)
if before == .notDetermined {
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { finish("mic before=notDetermined prompted=yes granted=\(granted)") }
    }
    app.run()
} else {
    finish("mic before=\(describe(before)) prompted=no")
}
