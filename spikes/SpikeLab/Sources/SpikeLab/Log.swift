import Foundation

enum Log {
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    static func line(_ s: String)   { print("\(fmt.string(from: Date()))  \(s)") }
    static func ok(_ s: String)     { line("✔ \(s)") }
    static func warn(_ s: String)   { line("! \(s)") }
    static func error(_ s: String)  { line("✘ \(s)") }
    static func header(_ s: String) { print("\n== \(s) ==") }
}

/// Render an OSStatus as number + four-char code when printable (e.g. 'who?', '!obj').
func describeStatus(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
    let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    return printable ? "\(status) '\(String(bytes: bytes, encoding: .ascii) ?? "")'" : "\(status)"
}
