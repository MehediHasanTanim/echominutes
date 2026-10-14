// SpikeLab entry point. Runs as a real .app (launched via run.sh → `open`) so macOS attributes
// privacy permissions (Microphone, System Audio Recording) to SpikeLab, not to Terminal.
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered so `open --stdout` log is live
setvbuf(stderr, nil, _IOLBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, but can show permission prompts

let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") }

Task { @MainActor in
    let code = await CommandRouter.run(Array(args))
    exit(code)
}
app.run()
