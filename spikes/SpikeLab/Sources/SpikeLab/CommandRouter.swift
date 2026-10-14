import Foundation

/// Add new spike commands here (EM-004 `processes`, EM-005 `capture`, …).
enum CommandRouter {
    struct Command {
        let name: String
        let summary: String
        let run: ([String]) async -> Int32
    }

    static let commands: [Command] = [
        Command(name: "info", summary: "Bundle, OS and code-signing details (hardened runtime, team, entitlements)", run: InfoCommand.run),
        Command(name: "mic", summary: "Show / request Microphone permission", run: MicCommand.run),
        Command(name: "tap-probe", summary: "Create + destroy a Core Audio process tap (checks the API & audio-capture usage string)", run: TapProbeCommand.run),
        Command(name: "all", summary: "Run info, mic and tap-probe (default)", run: { _ in await runAll() }),
        Command(name: "help", summary: "List commands", run: { _ in printHelp(); return 0 }),
    ]

    static func run(_ args: [String]) async -> Int32 {
        let name = args.first ?? "all"
        guard let cmd = commands.first(where: { $0.name == name }) else {
            Log.error("Unknown command '\(name)'"); printHelp(); return 2
        }
        Log.header("SpikeLab \(name)")
        return await cmd.run(Array(args.dropFirst()))
    }

    private static func runAll() async -> Int32 {
        var worst: Int32 = 0
        for name in ["info", "mic", "tap-probe"] {
            Log.header(name)
            let code = await commands.first { $0.name == name }!.run([])
            worst = max(worst, code)
        }
        Log.line(worst == 0 ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED (exit \(worst))")
        return worst
    }

    private static func printHelp() {
        Log.line("Usage: run.sh <command> [args]")
        for c in commands { Log.line("  \(c.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(c.summary)") }
    }
}
