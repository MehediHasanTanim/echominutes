import AppKit
import EMAudio
import EMCore
import SwiftUI

/// Floating recording widget (EM-073): elapsed time, mic + call meters, bookmark, stop. A non-activating
/// panel on all Spaces, so clicking it never steals focus from the meeting app. Position is remembered.
@MainActor
final class MiniWidgetController {
    private var panel: NSPanel?
    private static let autosaveName = "EchoMinutesMiniWidget.v2"     // v2: ignore the frame saved by the first build

    var isVisible: Bool { panel != nil }

    func show(state: AppState) {
        if let panel {
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        Log.info(.ui, "Mini widget: creating panel")
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
                        styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.contentView = NSHostingView(rootView: MiniWidgetView().environment(state))
        // Restore the saved position only if it is fully on a screen's visible area (not under the Dock/menu bar
        // or on a disconnected display); otherwise start at the top-right of the main screen.
        // Note: restore BEFORE setting the autosave name — setting the name first saves the initial (0,0) frame.
        let restored = p.setFrameUsingName(Self.autosaveName)
        if !restored || !NSScreen.screens.contains(where: { $0.visibleFrame.contains(p.frame) }) {
            let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 20, y: f.maxY - p.frame.height - 20))
        }
        p.setFrameAutosaveName(Self.autosaveName)
        p.orderFrontRegardless()
        panel = p
        Log.info(.ui, "Mini widget shown at \(NSStringFromRect(p.frame))")
    }

    func hide() {
        if panel != nil { Log.info(.ui, "Mini widget hidden") }
        panel?.orderOut(nil)
        panel = nil
    }
}

struct MiniWidgetView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(isPaused ? Color.orange : Color.red).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let i = state.recording.info {
                        if isPaused { Text("Paused").font(.headline) }
                        else { Text(i.startedAt, style: .timer).font(.headline.monospacedDigit()) }
                        Text(i.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                MeterBar(label: "You", db: state.levels?.micDB)
                MeterBar(label: "Call", db: state.levels?.systemDB)
            }
            Spacer(minLength: 4)
            Button { Task { await state.addBookmark() } } label: {
                Image(systemName: state.bookmarksThisRecording > 0 ? "bookmark.fill" : "bookmark")
            }
            .help("Bookmark this moment (⌃⌥⌘B)")
            .overlay(alignment: .topTrailing) {
                if state.bookmarksThisRecording > 0 {
                    Text("\(state.bookmarksThisRecording)").font(.system(size: 9).bold()).offset(x: 6, y: -6)
                }
            }
            Button { Task { await state.stopRecording() } } label: { Image(systemName: "stop.fill") }
                .help("Stop & save (⌃⌥⌘R)")
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: 300, height: 64)
    }

    private var isPaused: Bool { if case .paused = state.recording { true } else { false } }
}

/// Horizontal meter: −60…0 dBFS, green → yellow → red.
struct MeterBar: View {
    let label: String
    let db: Float?

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            GeometryReader { g in
                let frac = CGFloat(max(0, min(1, ((db ?? -120) + 60) / 60)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(color).frame(width: g.size.width * frac)
                }
            }
            .frame(height: 5)
        }
    }

    private var color: Color {
        guard let db else { return .green }
        return db > -6 ? .red : db > -18 ? .yellow : .green
    }
}
