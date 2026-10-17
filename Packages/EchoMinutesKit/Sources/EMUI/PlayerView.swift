import AVFoundation
import EMAudio
import EMCore
import Observation
import SwiftUI

/// Playback of one meeting (EM-122), shared by the player, transcript highlight and action-item links.
/// "Listen to" switches between the balanced mix, only your mic, or only the call — keeping the position.
@MainActor
@Observable
final class SessionPlayback {
    enum Source: String, CaseIterable, Identifiable {
        case everyone = "Everyone", me = "Only me", others = "Only the call"
        var id: String { rawValue }
        var file: String { switch self { case .everyone: "mixed.m4a"; case .me: "mic.m4a"; case .others: "system.m4a" } }
    }
    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var available = false
    var rate: Float = 1 { didSet { player?.rate = rate } }
    private(set) var source: Source = .everyone
    private var directory: URL?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    var currentMs: Int { Int(currentTime * 1000) }

    func load(_ dir: URL, source: Source = .everyone) {
        let wasPlaying = isPlaying, at = currentTime
        stop()
        directory = dir
        self.source = source
        let url = dir.appendingPathComponent(source.file)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.enableRate = true
        player?.rate = rate
        player?.prepareToPlay()
        available = player != nil
        duration = player?.duration ?? 0
        seek(seconds: at)
        if wasPlaying { play() }
    }

    func switchSource(_ s: Source) {
        guard s != source, let directory else { return }
        load(directory, source: s)
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() { player?.pause(); isPlaying = false; timer?.invalidate(); timer = nil }
    func toggle() { isPlaying ? pause() : play() }

    func seek(seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(player.duration, seconds))
        currentTime = player.currentTime
    }
    func seek(fraction: Double) { seek(seconds: max(0, min(1, fraction)) * duration) }
    func skip(_ delta: TimeInterval) { seek(seconds: currentTime + delta) }

    /// Seek and start playing (transcript line, bookmark, action item, search hit).
    func play(atMs ms: Int) { seek(seconds: Double(ms) / 1000); if !isPlaying { play() } }

    func stop() { player?.stop(); isPlaying = false; timer?.invalidate(); timer = nil }

    private func tick() {
        guard let p = player else { return }
        currentTime = p.currentTime
        if !p.isPlaying { isPlaying = false; timer?.invalidate(); timer = nil }
    }
}

struct PlayerView: View {
    @Environment(AppState.self) private var state
    let session: Session
    let directory: URL
    @Bindable var playback: SessionPlayback
    @State private var peaks: [Float] = []
    @State private var manifest: RecordingManifest?
    @State private var bookmarks: [Bookmark] = []
    @State private var remixing = false
    @State private var remixError: String?
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !playback.available {
                Label("The audio of this meeting was deleted — transcript, summary and notes are kept.", systemImage: "speaker.slash")
                    .foregroundStyle(.secondary)
            } else {
                controls
                WaveformView(peaks: peaks, progress: playback.duration > 0 ? playback.currentTime / playback.duration : 0,
                             markers: bookmarks.map { playback.duration > 0 ? Double($0.atMs) / 1000 / playback.duration : 0 }) {
                    playback.seek(fraction: $0)
                }
                .frame(height: 56)
                DisclosureGroup("Audio details", isExpanded: $showDetails) { details }
                    .font(.caption)
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.transcriptVersion) { if !state.hasAudio(session.id) { playback.load(directory) } }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { playback.skip(-15) } label: { Image(systemName: "gobackward.15") }.help("Back 15 s")
            Button { playback.toggle() } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
            }
            Button { playback.skip(15) } label: { Image(systemName: "goforward.15") }.help("Forward 15 s")
            Text("\(fmt(playback.currentTime)) / \(fmt(playback.duration))").monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Picker("Speed", selection: $playback.rate) {
                ForEach(SessionPlayback.rates, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
            }
            .fixedSize()
            Picker("Listen to", selection: Binding(get: { playback.source }, set: { playback.switchSource($0) })) {
                ForEach(SessionPlayback.Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            .disabled(manifest?.includesMic == false)
            Button { Task { await state.addBookmarkToSession(session.id, atMs: playback.currentMs); loadBookmarks() } } label: {
                Image(systemName: "bookmark")
            }
            .help("Bookmark this moment")
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !bookmarks.isEmpty {
                HStack(spacing: 6) {
                    Text("Bookmarks:").foregroundStyle(.secondary)
                    ForEach(bookmarks) { b in
                        Button(fmt(Double(b.atMs) / 1000)) { playback.play(atMs: b.atMs) }.buttonStyle(.link)
                    }
                }
            }
            if let mix = manifest?.mix {
                Text("Levels — you: \(db(mix.micLevelDB)) → \(gain(mix.micGainDB)) · others: \(db(mix.systemLevelDB)) → \(gain(mix.systemGainDB))")
                    .foregroundStyle(.secondary)
            }
            if let devices = manifest?.devices { Text("Devices: \(devices)").foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button(manifest?.mix == nil ? "Balance voice levels" : "Rebuild mix") { Task { await remix() } }
                    .disabled(remixing)
                if remixing { ProgressView().controlSize(.small) }
                if let remixError { Text(remixError).foregroundStyle(.red) }
            }
        }
        .padding(.top, 4)
    }

    private func load() {
        playback.load(directory)
        peaks = AudioFinalizer.loadWaveform(directory.appendingPathComponent("waveform.bin"))
        manifest = try? RecordingManifest.load(from: directory)
        loadBookmarks()
    }

    private func loadBookmarks() { bookmarks = state.bookmarks(for: session.id) }

    private func remix() async {
        remixing = true; remixError = nil
        playback.stop()
        let dir = directory
        do { _ = try await Task.detached(priority: .userInitiated) { try AudioFinalizer.remix(sessionDirectory: dir) }.value }
        catch { remixError = "Rebuild failed: \(error.localizedDescription)" }
        load()
        remixing = false
    }

    private func db(_ v: Float?) -> String { v.map { String(format: "%.0f dBFS", $0) } ?? "silent" }
    private func gain(_ v: Float) -> String { String(format: "%+.0f dB", v) }
    private func fmt(_ t: TimeInterval) -> String {
        let s = Int(t); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Peaks with played part highlighted and bookmark ticks (fractions 0…1). Click/drag to seek.
struct WaveformView: View {
    let peaks: [Float]
    let progress: Double
    var markers: [Double] = []
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                guard !peaks.isEmpty else { return }
                let bars = max(1, Int(size.width / 3))
                let per = max(1, peaks.count / bars)
                for b in 0..<min(bars, peaks.count) {
                    let slice = peaks[(b * per)..<min(peaks.count, (b + 1) * per)]
                    let h = max(1, CGFloat(slice.max() ?? 0) * size.height)
                    let rect = CGRect(x: CGFloat(b) * 3, y: (size.height - h) / 2, width: 2, height: h)
                    ctx.fill(Path(rect), with: .color(Double(b) / Double(bars) <= progress ? Color.accentColor : Color.gray.opacity(0.5)))
                }
                for m in markers {
                    let x = CGFloat(m) * size.width
                    ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.orange))
                }
                let px = CGFloat(progress) * size.width
                ctx.fill(Path(CGRect(x: px - 0.5, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.6)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { onSeek($0.location.x / g.size.width) })
        }
    }
}
