# EchoMinutes — Technical Design

| Field | Value |
|---|---|
| Product | EchoMinutes (personal macOS utility) |
| Document | Technical design v0.2 |
| Companion | [FEATURE_SPEC.md](FEATURE_SPEC.md) v0.2 — requirement IDs (FR-xxx) refer to it |
| Owner | Tanim Kabir |
| Date | 2026-10-14 |
| Status | Draft |

---

## 1. Scope & design principles

This document describes **how** EchoMinutes is built: architecture, modules, core algorithms, data storage, provider integrations, security, testing and delivery plan. It covers the MVP (Feature Spec §13 Phase 1) in detail and notes where Phase 2/3 features plug in.

Design principles:

1. **Local-first.** Everything is stored on the Mac. Network calls happen only to the provider the user picked, with the user's key.
2. **Never lose audio.** Capture is decoupled from processing; audio is persisted in small chunks; processing is a resumable job queue.
3. **Real-time safety.** Core Audio callbacks never allocate, lock, log or touch Swift actors — they only copy samples into lock-free ring buffers.
4. **Pluggable engines.** Transcription and LLM providers sit behind protocols so engines can be swapped without touching the rest of the app.
5. **Single user, single Mac.** No accounts, sync or server. Keep it simple; avoid speculative abstraction.

---

## 2. Key technical decisions

| # | Decision | Rationale | Alternatives rejected |
|---|---|---|---|
| TD-1 | Native **Swift 6 + SwiftUI** (AppKit where needed), min **macOS 14.4** | Process taps & audio process-object APIs require 14.2/14.4; best performance & battery | Electron/Tauri (no access to Core Audio process taps without native bridge) |
| TD-2 | **Core Audio Process Taps** for remote-participant audio | Per-app capture, no virtual driver, excludes other apps' sound | BlackHole/Loopback (driver install), ScreenCaptureKit (kept as fallback only) |
| TD-3 | Detection driven by **Core Audio process objects**: process-list listener + **1 s poll** of `kAudioProcessPropertyIsRunningInput/Output` | Tells exactly which app is using the mic. *Spike EM-004: per-process state listeners never fire on macOS 26.6 — polling ~36 objects/s is negligible CPU and the 5 s debounce hides the ≤1 s latency* | Per-process listeners only (unreliable), `lsof`/IOKit, window titles |
| TD-4 | **Start capture at "candidate" stage** (during debounce) into a ring buffer | Gives pre-roll for free — first words are not lost | Start only after debounce (loses 5 s) |
| TD-5 | **WhisperKit** (Core ML) for local STT; **download model on first use** (default large-v3-turbo, smaller optional) | Fast on Apple Silicon/ANE; built-in model download; keeps app ~20 MB | Bundling model (1.5 GB app, slow updates); whisper.cpp (good fallback) |
| TD-6 | **Two separate tracks** (mic + system) transcribed independently | "Me" vs "Others" attribution with no ML; simpler diarization | Single mixed track + full diarization |
| TD-7 | **GRDB (SQLite + FTS5)** for persistence | Mature, migrations, fast full-text search, Swift concurrency support | Core Data / SwiftData (weaker FTS, harder migrations) |
| TD-8 | API keys only in **Keychain** | OS-level encrypted storage | Config files / UserDefaults |
| TD-9 | **Not sandboxed**, Developer-ID/local signing; Sparkle optional later | Process taps + process enumeration simplest outside sandbox; personal tool | Mac App Store (sandbox risk, review) |
| TD-10 | LLM output as **JSON validated against a schema** | Reliable rendering of action items, decisions | Free-form Markdown parsing |

---

## 3. System architecture

### 3.1 High-level component view

```
┌─────────────────────────────── EchoMinutes.app (LSUIElement menu bar agent) ───────────────────────────────┐
│                                                                                                              │
│  UI layer (SwiftUI, @MainActor)                                                                              │
│  ┌──────────┐ ┌──────────────┐ ┌───────────┐ ┌────────────────┐ ┌───────────┐ ┌────────────┐                │
│  │ MenuBar  │ │ MiniWidget   │ │ Library   │ │ SessionDetail  │ │ Settings  │ │ Onboarding │                │
│  └────┬─────┘ └──────┬───────┘ └─────┬─────┘ └───────┬────────┘ └─────┬─────┘ └─────┬──────┘                │
│       └──────────────┴─────── AppState (@Observable, @MainActor) ──────┴─────────────┘                       │
│                                        │ commands / async streams                                            │
│  Domain services (actors)              ▼                                                                     │
│  ┌──────────────────┐   events   ┌──────────────────┐  finished  ┌──────────────────┐                        │
│  │ DetectionService │──────────▶│ SessionCoordinator│──────────▶│ JobQueue          │                        │
│  │  AudioProcessMon │           │  (state machine)  │           │  TranscribeJob    │                        │
│  │  AppWatcher      │           └────────┬─────────┘           │  SummarizeJob     │                        │
│  │  BrowserMatcher  │                    │ start/stop          │  FinalizeAudioJob │                        │
│  │  RulesEngine     │                    ▼                     └────────┬─────────┘                        │
│  └──────────────────┘           ┌──────────────────┐                    │                                   │
│                                 │ RecordingService │                    ▼                                   │
│                                 │  MicCapture      │          ┌───────────────────┐  ┌──────────────────┐   │
│                                 │  ProcessTapCapture│         │ TranscriptionKit  │  │ SummarizationKit │   │
│                                 │  RingBuffers     │          │  WhisperKitEngine │  │  LLMProvider ×N  │   │
│                                 │  ChunkWriter     │          │  CloudSTT ×N      │  │  Templates       │   │
│                                 └────────┬─────────┘          │  Diarizer         │  │  MapReduce       │   │
│                                          │                    └─────────┬─────────┘  └────────┬─────────┘   │
│  Infrastructure                          ▼                              ▼                     ▼             │
│  ┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐   │
│  │ Storage (GRDB/SQLite+FTS5) │ FileStore (audio chunks, models) │ KeychainStore │ Settings │ Logger    │   │
│  └──────────────────────────────────────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
          │ HTTPS (only if a cloud provider is selected)
          ▼
   Anthropic / OpenAI / Gemini / Azure / OpenRouter / Deepgram …   ·   Ollama / LM Studio (localhost)
```

### 3.2 End-to-end flow (happy path)

```
Zoom joins call ─▶ Zoom process starts using mic
   │
   ▼
AudioProcessMonitor: process(us.zoom.xos).isRunningInput = true
   │
   ▼
RulesEngine: watched app, mode=Auto, not in private hours ─▶ SessionCoordinator: Idle → Candidate
   │                                                         RecordingService.startCapture(to: ring buffer only)
   ▼ (input still running after 5 s debounce)
SessionCoordinator: Candidate → Recording ─▶ flush ring buffer (pre-roll) to chunk files; notify user
   │
   ▼ (Zoom stops mic + output for 15 s grace)
SessionCoordinator: Recording → Finalizing ─▶ close chunks, insert jobs
   │
   ▼
JobQueue: FinalizeAudio (concat chunks, mixdown) → Transcribe (mic & system) → Merge/Diarize → Summarize
   │
   ▼
Session status = Ready; notification "Summary ready"
```

---

## 4. Project structure

Xcode app target + local Swift packages (modular, testable, fast incremental builds).

```
EchoMinutes/
├── EchoMinutes.xcodeproj
├── App/                          # @main, AppDelegate, menu bar, windows, DI container
│   ├── EchoMinutesApp.swift
│   ├── AppState.swift
│   ├── Info.plist
│   └── EchoMinutes.entitlements
├── Packages/
│   ├── EMCore/                   # Models, IDs, errors, Clock protocol, utilities
│   ├── EMDetection/              # AudioProcessMonitor, AppWatcher, BrowserMatcher, RulesEngine
│   ├── EMAudio/                  # MicCapture, ProcessTapCapture, RingBuffer, ChunkWriter, Mixdown
│   ├── EMSession/                # SessionCoordinator state machine
│   ├── EMStorage/                # GRDB database, migrations, repositories, FileStore, KeychainStore
│   ├── EMTranscription/          # TranscriptionEngine protocol, WhisperKitEngine, cloud engines, Diarizer, ModelManager
│   ├── EMSummarization/          # LLMProvider protocol, provider adapters, templates, map-reduce, schema validation
│   ├── EMJobs/                   # Persistent JobQueue + job handlers
│   ├── EMExport/                 # Markdown, TXT, SRT/VTT, PDF, DOCX renderers
│   └── EMUI/                     # SwiftUI views & view models
├── Resources/
│   ├── DetectionRules.json       # bundled app/browser detection rules
│   ├── Templates/                # built-in summary templates (JSON)
│   └── Pricing.json              # token price table (editable)
└── Tests/
    ├── EMDetectionTests/  EMSessionTests/  EMSummarizationTests/  EMStorageTests/ …
    └── Fixtures/                 # sample audio, transcripts, provider responses
```

### 4.1 Dependencies

| Package | Purpose |
|---|---|
| `argmaxinc/WhisperKit` | Local speech-to-text (Core ML) + model download |
| `groue/GRDB.swift` | SQLite, migrations, FTS5, observation |
| `apple/swift-atomics` | Lock-free ring buffer indices |
| `sindresorhus/KeyboardShortcuts` | Global hotkeys |
| `sparkle-project/Sparkle` (optional, later) | Auto-update |
| Diarization: `FluidInference/FluidAudio` (Core ML speaker diarization) — **to validate in spike S4** | "Speaker 1/2/…" on system track |

Everything else uses Apple frameworks: CoreAudio, AVFoundation, ScreenCaptureKit, AppKit, SwiftUI, UserNotifications, EventKit, Security, ServiceManagement, os.

---

## 5. Concurrency model

| Context | Runs on | Rules |
|---|---|---|
| Core Audio IO procs / AVAudioEngine taps | Real-time audio threads | No allocation, no locks, no `await`, no logging. Copy frames into `SPSCRingBuffer` only. |
| `ChunkWriter` | Dedicated serial `DispatchQueue` (utility QoS) | Drains ring buffers every ~100 ms, converts format, encodes AAC, rotates files |
| `DetectionService`, `SessionCoordinator`, `RecordingService`, `JobQueue` | Swift `actor`s | All state mutation inside the actor; communicate via `AsyncStream` |
| Core Audio property listeners | Private dispatch queue → hop into actor via `Task` | Listener blocks only enqueue events |
| Transcription / LLM work | Detached tasks with `.utility` priority, max 1 heavy STT job at a time | Cooperative cancellation; progress via `AsyncStream` |
| UI | `@MainActor` | `AppState` subscribes to service streams and GRDB `ValueObservation` |

Swift 6 strict concurrency is enabled. Core Audio C types are wrapped in small `@unchecked Sendable` structs with documented invariants.

---

## 6. Meeting detection (EMDetection)

### 6.1 Signals

| Signal | API | Use |
|---|---|---|
| Running apps | `NSWorkspace.didLaunchApplicationNotification` / `didTerminate…` | Know which watched apps are alive |
| **Process using mic** | `kAudioHardwarePropertyProcessObjectList` (listener ✔) + per-process `kAudioProcessPropertyIsRunningInput` (**polled every 1 s** — listeners don't fire), `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyPID` | **Primary trigger** |
| Process producing audio | `kAudioProcessPropertyIsRunningOutput` (polled) | Secondary only — helpers keep output on after calls (Teams) and browsers hold output after pause; never a start signal |
| Any mic in use (fallback) | `kAudioDevicePropertyDeviceIsRunningSomewhere` on input devices | Fallback if process list unavailable |
| Browser tab/window titles | ScreenCaptureKit `SCShareableContent.windows` titles (needs Screen Recording) or AX API | Browser meeting matching (Phase 2) |
| Calendar event | EventKit | Titles/attendees (Phase 2) |
| Sleep/wake | `NSWorkspace.willSleepNotification` | Finalize on sleep |

### 6.2 Process → app attribution

Meeting apps often do audio in **helper processes** (e.g., `com.microsoft.teams2.helper…`, Chrome's audio service helper). Attribution rules:

1. Read `kAudioProcessPropertyBundleID` of the audio process.
2. Match against `DetectionRules.json` using **bundle ID prefix** (`com.microsoft.teams2` matches `com.microsoft.teams2.helper.*`).
3. If bundle ID is empty, map PID → responsible app via `NSRunningApplication(processIdentifier:)` / parent PID lookup.
4. Exclude EchoMinutes' own PID (we also use the mic while recording).

`DetectionRules.json` (bundled, user-overridable):

```json
{
  "version": 1,
  "apps": [
    { "id": "teams",    "name": "Microsoft Teams", "bundlePrefixes": ["com.microsoft.teams2"], "debounceSec": 5, "graceSec": 15 },
    { "id": "zoom",     "name": "Zoom",            "bundlePrefixes": ["us.zoom.xos", "us.zoom"], "debounceSec": 5, "graceSec": 15 },
    { "id": "whatsapp", "name": "WhatsApp",        "bundlePrefixes": ["net.whatsapp.WhatsApp"], "debounceSec": 8, "graceSec": 15 }
  ],
  "browsers": [
    { "bundlePrefixes": ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser", "org.mozilla.firefox"],
      "titlePatterns": ["^Meet - ", "meet\\.google\\.com", "\\| Microsoft Teams", "Zoom Meeting"] }
  ]
}
```

> Verified in spikes EM-004…006 (see `docs/spikes/S1-S2.md`, draft rules in `Resources/DetectionRules.json`):
> - **Teams** `com.microsoft.teams2*` — call mic + audio in the *main* process; helpers `.helper` ×3, `.modulehost`, `.notificationcenter`.
> - **WhatsApp** `net.whatsapp.WhatsApp*` — includes `net.whatsapp.WhatsApp.ServiceExtension` (separate call process).
> - **Zoom** `us.zoom*` — `us.zoom.xos` + `us.zoom.caphost`.
> - **Ignore** `com.apple.CoreSpeech` (Siri/voice trigger toggles the mic on its own).

### 6.3 AudioProcessMonitor (sketch)

```swift
actor AudioProcessMonitor {
    struct Activity: Sendable { let bundleID: String; let pid: pid_t; var input: Bool; var output: Bool }
    let events: AsyncStream<[Activity]>          // full snapshot on every change

    func start() throws {
        // 1. listen to kAudioHardwarePropertyProcessObjectList on kAudioObjectSystemObject (fires reliably)
        // 2. every 1 s (DispatchSourceTimer on the monitor queue): read IsRunningInput / IsRunningOutput
        //    of every process object; also re-read immediately after a process-list change
        // 3. if any state changed: rebuild snapshot, yield to `events`
        // (per-process property listeners register OK but never fire on macOS 26.6 — EM-004)
    }
}
```

The process-list listener and the poll timer run on one private serial queue; they only diff state and call `continuation.yield(snapshot())`. Optional: a `kAudioDevicePropertyDeviceIsRunningSomewhere` device listener as an extra re-scan trigger (still being evaluated).

### 6.4 Rules engine & state machine

Detection emits `MeetingSignal` events to the `SessionCoordinator`:

```swift
enum MeetingSignal: Sendable {
    case micStarted(app: WatchedApp, pids: [pid_t], at: ContinuousClock.Instant)
    case micStopped(app: WatchedApp, at: ContinuousClock.Instant)
    case outputChanged(app: WatchedApp, active: Bool)
    case appTerminated(app: WatchedApp)
    case systemWillSleep
    case manualStart(apps: [WatchedApp]), manualStop
}
```

```
                 micStarted(app) & rules allow (mode=Auto)
      ┌──────┐ ─────────────────────────────────────────▶ ┌───────────┐
      │ Idle │                                            │ Candidate │  capture → ring buffer only
      └──────┘ ◀──────────── micStopped before debounce ── └─────┬─────┘
          ▲                                                      │ debounce elapsed, mic still on
          │                                                      ▼
          │       Discard                                 ┌───────────┐ ⇄ Paused (user)
          ├────────────────────────────────────────────── │ Recording │
          │                                               └─────┬─────┘
          │                                                     │ mic off & output off for graceSec
          │                                                     │ OR appTerminated OR sleep OR manualStop
          │                                                     ▼
          │                                               ┌────────────┐
          └────────────────────────────────────────────── │ Finalizing │ → enqueue jobs
                                                          └────────────┘
```

Rules (all timers use an injected `Clock` for testability):

- **Debounce:** per-app `debounceSec` (default 5 s; WhatsApp 8 s to skip voice notes).
- **Grace:** end only when the app has **neither input nor output** for `graceSec` (default 15 s). If mic stops but output continues (user muted and app released the device), extend grace up to 60 s while output is active.
- **Exclusions:** mode `never`, private-hours window, (optional) Focus filter → stay `Idle`.
- **Mode `ask`:** `Candidate` waits for notification action; ring buffer keeps last 60 s so accepting late still has the audio.
- **Concurrency:** while `Recording`, a `micStarted` from a different app only posts a "Switch to <app>" notification.

---

## 7. Audio capture (EMAudio)

### 7.1 Capture graph

```
 Microphone (default input) ──▶ MicCapture (AVAudioEngine inputNode tap, native format)
                                     │ float32 frames + host time
                                     ▼
                              SPSCRingBuffer[mic]  ──┐
                                                     ├──▶ ChunkWriter (serial queue)
 Meeting app process(es) ──▶ ProcessTapCapture       │      • resample → 48 kHz mono float
   CATapDescription  ─▶ Process Tap ─▶ private       │      • align by host time
   aggregate device ─▶ IOProc (RT thread)            │      • AAC encode → 30 s .m4a chunks
                                     ▼               │      • level meters (RMS) → UI
                              SPSCRingBuffer[sys] ───┘
```

### 7.2 Process tap setup (system track)

1. Resolve target PIDs (all processes attributed to the meeting app, §6.2) → audio object IDs via `kAudioHardwarePropertyTranslatePIDToProcessObject`.
2. Build `CATapDescription` stereo mixdown of the process objects via a 2-function **Objective-C shim** (`initStereoMixdownOfProcesses:` with `NSArray<NSNumber *>`, proven in SpikeLab `TapShim`); set `desc.isPrivate = true`, default mute behaviour (user still hears the call). Include **all** processes matching the app's bundle prefixes.
3. `AudioHardwareCreateProcessTap(desc, &tapID)`.
4. Create a **private aggregate device** (`AudioHardwareCreateAggregateDevice`) with:
   - `kAudioAggregateDeviceIsPrivateKey: true`
   - `kAudioAggregateDeviceMainSubDeviceKey`: current default output device UID (clock source)
   - `kAudioAggregateDeviceTapListKey`: `[[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]`
   - `kAudioAggregateDeviceTapAutoStartKey: true`
5. Read tap stream format (`kAudioTapPropertyFormat`), `AudioDeviceCreateIOProcIDWithBlock` → copy input buffers into ring buffer; `AudioDeviceStart`.
6. Teardown in reverse: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.

**Measured (EM-005/006):** tap format 48 kHz / 2 ch / Float32 interleaved; setup ≈ 25 ms; first **40–300 ms** after start are digital silence (spin-up) → capture must start in *Candidate* state. Call audio from Teams/WhatsApp is mono duplicated to both channels. Silence behaviour differs per app: Teams ≈ −70 dBFS comfort noise, WhatsApp/Zoom digital zeros with callbacks continuing, Chrome **no frames at all** → the writer must gap-fill by host time, never assume continuous frames.

The first tap creation triggers the macOS "System Audio Recording" consent (`NSAudioCaptureUsageDescription`). There is no public API to query this permission; Diagnostics verifies it by checking that the tap delivers non-silent audio during a test sound.

**New helper processes mid-call** (e.g., Teams spawns a new audio helper): `AudioProcessMonitor` notices the new process object → `RecordingService` rebuilds the tap with the new PID set; a gap of < 100 ms is acceptable and a marker is written.

**Fallback (S1 failure / older OS):** `SCStream` with `capturesAudio = true`, `excludesCurrentProcessAudio = true`, filtered to the meeting app's `SCRunningApplication`.

### 7.3 Microphone capture (mic track)

- `AVAudioEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil)` in the native format; frames copied to ring buffer.
- Observe `AVAudioEngineConfigurationChange` and default-device changes (`kAudioHardwarePropertyDefaultInputDevice`) → restart engine on the new device, write a `deviceChanged` marker.
- Voice processing is **off** (we want the raw mic; the meeting app already does its own processing).

### 7.4 Ring buffer & pre-roll

- `SPSCRingBuffer<Float>`: fixed capacity (60 s × 48 kHz × 2 ch ≈ 23 MB per track, allocated once at app start), single producer (RT thread) / single consumer (writer), indices via `swift-atomics`.
- In `Candidate` state the writer **does not** drain to disk; it only keeps the last N seconds. On transition to `Recording` it drains everything (= pre-roll) then continues live.
- Overrun policy: drop oldest frames and increment an `overrunCount` metric (should be 0 in practice).

### 7.5 Encoding & chunking

- Normalize to **48 kHz, mono, Float32** via `AVAudioConverter` (system tap is stereo mixdown → downmix).
- Encode AAC-LC 64 kbps mono with `AVAudioFile(forWriting:settings:)` into **30-second `.m4a` chunks** (`mic/000001.m4a`, `system/000001.m4a`, …). Each chunk is closed (moov atom written) on rotation, so a crash loses ≤ 30 s.
- Track alignment: each chunk's first-sample host time is stored in the session manifest; the writer inserts silence to fill gaps so both tracks stay sample-aligned to a common session timeline (t=0 = first pre-roll sample).
- Disk guard: before each rotation check free space (`volumeAvailableCapacityForImportantUsage`): warn < 2 GB, safe-stop < 500 MB.

### 7.6 Finalization (FinalizeAudioJob)

1. Concatenate chunks per track with `AVMutableComposition` → export `mic.m4a`, `system.m4a` (passthrough, no re-encode).
2. Create `mixed.m4a` (both tracks summed, −3 dB each) for playback.
3. Compute waveform peaks (e.g., 2 per 100 ms) → `waveform.bin` for the UI.
4. Verify durations match manifest ± 1 s, then delete chunk folders.

### 7.7 Echo handling (speakers instead of headphones)

When the output device is built-in speakers, remote voices leak into the mic track and would be transcribed twice as "Me".

- **Detection:** output device `kAudioDevicePropertyTransportType == kAudioDeviceTransportTypeBuiltIn` and data source "speakers" → flag session `echoRisk = true`.
- **MVP mitigation (transcript-level):** after transcription, drop/merge a mic segment when (a) it overlaps a system segment in time, (b) normalized text similarity ≥ 0.8, and (c) system-track RMS in that window exceeds mic-track RMS by a threshold. Cheap and robust.
- **Phase 2:** signal-level AEC (subtract delayed, filtered system track from mic using an adaptive NLMS filter) before STT.

---

## 8. Session lifecycle (EMSession)

`SessionCoordinator` (actor) owns the state machine in §6.4 and orchestrates `RecordingService`, storage, and notifications.

| Transition | Side effects |
|---|---|
| Idle → Candidate | Create in-memory `PendingSession`; start mic + tap capture into ring buffers |
| Candidate → Idle | Stop capture; discard buffers; nothing persisted |
| Candidate → Recording | Insert `sessions` row (status `recording`); create folder; drain pre-roll; post notification "Recording <App>… [Stop] [Discard]"; menu bar red |
| Recording ⇄ Paused | Writer stops draining (buffers continue but are dropped); `pause`/`resume` markers |
| Recording → Finalizing | Stop capture; close chunks; write manifest; status `finalizing`; enqueue `finalizeAudio` job |
| any → Discarded | Stop capture; delete folder & row |

**Crash recovery:** at launch, any `sessions` row in `recording/paused/finalizing` is marked `interrupted`; the app offers **Recover**, which runs `FinalizeAudioJob` on existing chunks.

---

## 9. Transcription (EMTranscription)

### 9.1 Engine abstraction

```swift
public struct STTOptions: Sendable {
    var language: String?            // nil = auto-detect
    var vocabulary: [String]         // custom terms → prompt/hints
    var wordTimestamps: Bool
}

public struct RawSegment: Sendable { var startMs: Int; var endMs: Int; var text: String; var confidence: Double? }

public protocol TranscriptionEngine: Sendable {
    var id: String { get }
    var isLocal: Bool { get }
    func prepare() async throws                                   // load model / validate key
    func transcribe(file: URL, options: STTOptions,
                    progress: @Sendable (Double) -> Void) async throws -> [RawSegment]
}
```

Implementations: `WhisperKitEngine` (MVP), `OpenAITranscriptionEngine`, `DeepgramEngine`, `AssemblyAIEngine` (Phase 2).

### 9.2 Local model management (ModelManager)

- **Decision:** models are **downloaded on first use** (during onboarding or first transcription), not bundled.
- Default: Whisper **large-v3-turbo** Core ML variant; options: small / base (faster), large-v3 (most accurate). Exact WhisperKit variant names are resolved from WhisperKit's model repository at runtime.
- Stored in `~/Library/Application Support/EchoMinutes/Models/<variant>/`; download with progress + resume (WhisperKit's downloader), integrity verified by WhisperKit; first load triggers Core ML specialization (one-time, may take 1–2 min — show "Optimizing model for this Mac…").
- Settings → Transcription shows installed models, size on disk, Delete.

### 9.3 Transcription pipeline (TranscribeJob)

```
mic.m4a ───▶ VAD (energy + WhisperKit VAD) ─▶ speech regions ─▶ engine.transcribe ─▶ segments(trackKind=mic, speaker=Me)
system.m4a ─▶ VAD ─────────────────────────▶ speech regions ─▶ engine.transcribe ─▶ segments(trackKind=system)
                                                                                         │
                                                                    Diarizer(system.m4a) ┤ assign Speaker 1..N
                                                                                         ▼
                                              merge by startMs ─▶ echo de-dup (§7.7) ─▶ persist transcript
```

- VAD skips silence (meetings are often ~40% silence on each track) → large speed-up and fewer hallucinations.
- Whisper hallucination guard: drop segments with no-speech probability > 0.6 or repeated n-gram loops.
- Language: auto-detect on first 30 s of speech per track; user can force a language per app/session (English, Bengali, …).
- Custom vocabulary passed as Whisper initial prompt (≤ 224 tokens).
- Performance target: ≤ 0.3× real-time on M1 with turbo (1 h → ≤ 18 min); job reports progress per track.

### 9.4 Diarization (system track)

- **MVP:** system track labelled "Others" (single speaker label) if diarization is disabled or fails; diarization enabled by default if spike S4 passes.
- Diarizer produces `(startMs, endMs, clusterId)` turns; each system segment gets the cluster with maximum overlap → `Speaker 1…N`.
- Mic track never diarized (always "Me").
- Speaker rename updates `speakers.display_name` (segments reference speaker IDs, so rename is O(1)).

### 9.5 Live transcript (Phase 2)

Separate low-latency path: writer also feeds 16 kHz mono frames to a `LiveTranscriber` using WhisperKit streaming (small model) with a sliding 15 s window; results are shown in the mini-widget only and replaced by the final pass.

---

## 10. Summarization (EMSummarization)

### 10.1 Provider abstraction

```swift
public struct LLMMessage: Sendable { enum Role { case system, user, assistant }; var role: Role; var content: String }

public struct LLMRequest: Sendable {
    var model: String
    var messages: [LLMMessage]
    var jsonSchema: JSONSchema?      // structured output when supported
    var maxOutputTokens: Int
    var temperature: Double = 0.2
}

public struct LLMResponse: Sendable { var text: String; var inputTokens: Int?; var outputTokens: Int? }

public protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    func testConnection() async throws
    func listModels() async throws -> [String]
    func complete(_ req: LLMRequest) async throws -> LLMResponse
    func stream(_ req: LLMRequest) -> AsyncThrowingStream<String, Error>
}
```

### 10.2 Provider adapters

| Provider | Endpoint (base) | Auth | Structured output |
|---|---|---|---|
| Anthropic | `POST https://api.anthropic.com/v1/messages` | `x-api-key`, `anthropic-version` header | JSON schema via tool definition / instructions + validation |
| OpenAI | `POST https://api.openai.com/v1/chat/completions` | `Authorization: Bearer` | `response_format: { type: json_schema }` |
| Google Gemini | `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` | `x-goog-api-key` | `responseMimeType: application/json` + `responseSchema` |
| Azure OpenAI | `{endpoint}/openai/deployments/{deployment}/chat/completions?api-version=…` | `api-key` | as OpenAI |
| OpenRouter | `https://openrouter.ai/api/v1/chat/completions` | Bearer | OpenAI-compatible |
| OpenAI-compatible | user base URL | optional Bearer | best-effort `json_schema`, else prompt-only |
| Ollama | `http://localhost:11434/api/chat` | none | `format: <schema>` |

- All adapters share an `HTTPClient` (URLSession, 120 s timeout, SSE parser for streaming).
- Model names are **not hard-coded**: populated from each provider's list-models endpoint, with a free-text override. A suggested default per provider is kept in a small remotely-editable JSON.
- `testConnection()` = list models (or a 1-token completion) and maps errors to user-friendly messages.

### 10.3 Summary pipeline (SummarizeJob)

1. Build transcript text: `[mm:ss] Speaker: text` lines (speaker display names applied).
2. Estimate tokens (`chars / 4`, provider-specific tokenizer later). If ≤ 70% of the model's context budget → single pass.
3. Otherwise **map-reduce**: split into ~8k-token chunks on segment boundaries with 1-minute overlap → map prompt produces partial JSON (points, decisions, action items with timestamps) → reduce prompt merges/deduplicates into final schema.
4. Validate JSON against `SummarySchema` (JSONSchema validator); on failure retry once with the validation error appended; on second failure store raw Markdown and mark `schemaValid = false`.
5. Persist `summaries` + `action_items`; compute cost from `Pricing.json`.
6. Session title: if user hasn't edited it, replace with `summary.title`.

`SummarySchema` (MVP):

```json
{
  "type": "object",
  "required": ["title", "tldr", "key_points", "decisions", "action_items", "open_questions", "next_steps"],
  "properties": {
    "title": { "type": "string" },
    "tldr": { "type": "string" },
    "key_points": { "type": "array", "items": { "type": "string" } },
    "decisions": { "type": "array", "items": { "type": "string" } },
    "action_items": { "type": "array", "items": {
      "type": "object", "required": ["task"],
      "properties": { "task": {"type":"string"}, "owner": {"type":["string","null"]},
                      "due": {"type":["string","null"]}, "timestamp": {"type":["string","null"]} } } },
    "open_questions": { "type": "array", "items": { "type": "string" } },
    "next_steps": { "type": "array", "items": { "type": "string" } }
  }
}
```

### 10.4 Templates

Templates are JSON: `{ id, name, systemPrompt, sections[], schemaOverrides?, autoRule? }`. Built-ins ship in `Resources/Templates/`; user templates stored in DB. `autoRule` example: `{ "appId": "zoom", "titleRegex": "(?i)stand-?up" }`.

### 10.5 Ask-the-meeting (Phase 2)

Single-session: whole transcript in context (or top-k segments via FTS5/BM25 for long meetings) + question → answer with `[mm:ss]` citations that the UI turns into seek links.

---

## 11. Persistence (EMStorage)

### 11.1 File layout

```
~/Library/Application Support/EchoMinutes/
├── echominutes.sqlite (+ -wal, -shm)
├── Sessions/
│   └── <session-uuid>/
│       ├── manifest.json            # tracks, chunk list, host-time anchors, markers
│       ├── chunks/mic/000001.m4a …  # only until finalized
│       ├── chunks/system/000001.m4a …
│       ├── mic.m4a  system.m4a  mixed.m4a
│       └── waveform.bin
├── Models/                          # WhisperKit models (downloaded on first use)
└── Logs/                            # rotated, redacted
```

### 11.2 Database schema (migration v1)

```sql
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,                       -- UUID
  title TEXT NOT NULL,
  title_is_user_edited INTEGER NOT NULL DEFAULT 0,
  source_app_id TEXT,                        -- 'teams' | 'zoom' | 'whatsapp' | 'manual' …
  source_bundle_id TEXT,
  started_at DATETIME NOT NULL,
  ended_at DATETIME,
  duration_ms INTEGER,
  status TEXT NOT NULL,                      -- recording|paused|finalizing|transcribing|summarizing|ready|failed|interrupted
  echo_risk INTEGER NOT NULL DEFAULT 0,
  stt_engine TEXT, llm_provider TEXT, llm_model TEXT, template_id TEXT,
  notes_md TEXT,
  tags TEXT,                                 -- JSON array
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL
);

CREATE TABLE audio_tracks (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,                        -- mic|system|mixed
  path TEXT NOT NULL, codec TEXT, sample_rate INTEGER, duration_ms INTEGER, size_bytes INTEGER
);

CREATE TABLE speakers (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  label TEXT NOT NULL, display_name TEXT, is_me INTEGER NOT NULL DEFAULT 0, color TEXT
);

CREATE TABLE transcript_segments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  speaker_id TEXT REFERENCES speakers(id),
  track_kind TEXT NOT NULL,
  start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
  text TEXT NOT NULL, confidence REAL, is_edited INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_segments_session_time ON transcript_segments(session_id, start_ms);

CREATE TABLE summaries (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  template_id TEXT, provider TEXT, model TEXT,
  json TEXT, markdown TEXT, schema_valid INTEGER NOT NULL,
  tokens_in INTEGER, tokens_out INTEGER, cost_usd REAL,
  is_current INTEGER NOT NULL DEFAULT 1, created_at DATETIME NOT NULL
);

CREATE TABLE action_items (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  summary_id TEXT REFERENCES summaries(id) ON DELETE SET NULL,
  text TEXT NOT NULL, owner TEXT, due TEXT, timestamp_ms INTEGER,
  is_done INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE bookmarks (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  at_ms INTEGER NOT NULL, note TEXT
);

CREATE TABLE templates (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, definition_json TEXT NOT NULL, is_builtin INTEGER NOT NULL
);

CREATE TABLE app_rules (
  app_id TEXT PRIMARY KEY, display_name TEXT NOT NULL, bundle_prefixes TEXT NOT NULL,   -- JSON
  mode TEXT NOT NULL DEFAULT 'auto',        -- auto|ask|never
  debounce_sec INTEGER, grace_sec INTEGER, local_only INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE provider_configs (              -- API keys are NOT stored here (Keychain)
  provider_id TEXT PRIMARY KEY, enabled INTEGER NOT NULL, model TEXT, base_url TEXT, extra_json TEXT
);

CREATE TABLE jobs (
  id TEXT PRIMARY KEY, session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE,
  type TEXT NOT NULL,                        -- finalizeAudio|transcribe|summarize|export
  status TEXT NOT NULL,                      -- queued|running|done|failed
  attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
  not_before DATETIME, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL
);

-- Full-text search
CREATE VIRTUAL TABLE search_fts USING fts5(
  session_id UNINDEXED, kind UNINDEXED, ref_id UNINDEXED, start_ms UNINDEXED, body,
  tokenize = 'unicode61 remove_diacritics 2'
);
```

`search_fts` is maintained by repository code (insert on transcript/summary/notes save, delete on session delete). Search query: `SELECT … FROM search_fts WHERE search_fts MATCH ? ORDER BY bm25(search_fts) LIMIT 50` with `snippet()` for highlighting; `start_ms` enables jump-to-timestamp.

### 11.3 Keychain (KeychainStore)

```swift
struct KeychainStore {
    static let service = "com.tanimkabir.echominutes.providers"
    func set(_ key: String, for provider: ProviderID) throws    // kSecClassGenericPassword, account = provider.rawValue,
                                                                 // kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    func get(_ provider: ProviderID) throws -> String?
    func delete(_ provider: ProviderID) throws
}
```

- Keys never leave Keychain except into the in-memory HTTP request header.
- UI shows masked form (`sk-…a9F2`); "Reveal" gated by `LAContext` Touch ID / password.
- Logging uses `privacy: .private` and a redaction filter on anything matching common key prefixes.

---

## 12. Job queue (EMJobs)

- DB-backed (`jobs` table) so work survives quit/crash; `JobQueue` actor polls on enqueue events and at launch.
- Pipeline per session: `finalizeAudio → transcribe → summarize` (each job enqueues the next on success).
- Concurrency: 1 heavy local STT job at a time; LLM jobs up to 2 concurrent.
- Retry: exponential backoff (30 s, 2 min, 10 min, 1 h) for network/rate-limit errors (`429`, `5xx`, timeouts); no retry for `401/403` (invalid key) — status `failed` with actionable message.
- Offline: if cloud provider and no network (`NWPathMonitor`), job waits; if local fallback enabled, transcription switches to local engine.
- Power: transcription defers when on battery < 20% unless user taps "Transcribe now" (`ProcessInfo.isLowPowerModeEnabled` respected).

---

## 13. UI layer (EMUI)

| Surface | Implementation |
|---|---|
| Menu bar | `MenuBarExtra` (window style) with status, controls, recent sessions; icon reflects `AppState.recordingState` |
| Mini widget | `NSPanel` (non-activating, floating) hosting SwiftUI: timer, two level meters, bookmark, stop |
| Main window | `NavigationSplitView`: sidebar (grouped sessions + filters + search) → detail |
| Session detail | Player (`AVPlayer` on `mixed.m4a`, per-track mute via `AVMutableAudioMix`), waveform canvas, tabs Summary / Transcript / Action Items / Notes / Ask |
| Transcript view | `LazyVStack` of segments; highlight current segment from player time (binary search on `start_ms`); click → seek |
| Settings | SwiftUI `Settings` scene with tabs per Feature Spec §10 |
| Notifications | `UNUserNotificationCenter` with categories `RECORDING_STARTED` (Stop, Discard), `SWITCH_APP`, `SUMMARY_READY` (Open) |
| Hotkeys | `KeyboardShortcuts` (start/stop, bookmark, discard) |

Data binding: GRDB `ValueObservation` → `AsyncSequence` → `@Observable` view models.

---

## 14. Permissions, entitlements & app configuration

**Info.plist**

| Key | Value |
|---|---|
| `LSUIElement` | `YES` (menu bar agent, no Dock icon; main window opened on demand) |
| `NSMicrophoneUsageDescription` | "EchoMinutes records your voice during meetings you attend." |
| `NSAudioCaptureUsageDescription` | "EchoMinutes records the audio of your meeting apps so remote participants appear in your transcript." |
| `NSScreenCaptureUsageDescription` (Phase 2) | For browser meeting detection / fallback capture |
| `NSCalendarsFullAccessUsageDescription` (Phase 2) | Name meetings from your calendar |

**Entitlements (Hardened Runtime, no App Sandbox)**

- `com.apple.security.device.audio-input` = true
- (no network entitlement needed outside sandbox)

**Signing:** use a stable signing identity (Apple Development or Developer ID). TCC permissions (mic, system audio) are tied to the code signature — ad-hoc signing makes macOS re-prompt after every rebuild.

**Launch at login:** `SMAppService.mainApp.register()`.

**Permission checks:**

| Permission | Check | Request |
|---|---|---|
| Microphone | `AVCaptureDevice.authorizationStatus(for: .audio)` | `requestAccess` |
| System audio | No API → functional test (tap returns non-silent audio while playing a test tone) | First tap creation |
| Screen recording | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()` |
| Notifications | `UNUserNotificationCenter.notificationSettings()` | `requestAuthorization` |

Deep links: `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` (and `…Privacy_AudioCapture`, `…Privacy_ScreenCapture`).

---

## 15. Security & privacy

| Threat / concern | Control |
|---|---|
| API key leakage | Keychain only; never in DB, logs, exports, crash reports; redaction filter |
| Meeting data exposure on disk | Files under user's Library with `0700` folder perms; FileVault assumed; optional AES-GCM encryption at rest (Phase 3, key in Keychain) |
| Unintended recording | Visible menu bar state + notification on every start; per-app Never; private hours; Discard |
| Data sent to cloud | Only the chosen provider; session records `stt_engine` / `llm_provider`; per-app `local_only` forces local engines |
| Transport | HTTPS only for cloud; `http://localhost` allowed only for Ollama/LM Studio |
| Prompt injection via transcript | Transcript wrapped in delimiters; system prompt instructs to treat it as data; output validated by schema; LLM has no tools/actions |
| Third-party dependencies | Pinned versions via SwiftPM `Package.resolved`; minimal dependency set |

---

## 16. Observability

- `os.Logger(subsystem: "com.tanimkabir.echominutes", category: …)` — categories: `detection`, `audio`, `session`, `stt`, `llm`, `jobs`, `storage`.
- Detection decisions logged with reason codes (`IGNORED_DEBOUNCE`, `IGNORED_RULE_NEVER`, `STARTED_AUTO`, `ENDED_GRACE`…) — essential for tuning per-app behaviour.
- Audio health metrics per session in manifest: ring overruns, gaps inserted, device changes, tap rebuilds, silent-track warnings.
- Diagnostics page: export a redacted log bundle (`OSLogStore` last 24 h + manifests, no audio/transcripts).

---

## 17. Testing strategy

| Level | What | How |
|---|---|---|
| Unit | Detection state machine (debounce, grace, mute, concurrency, exclusions) | Feed scripted `MeetingSignal` sequences with a `TestClock`; assert transitions |
| Unit | Ring buffer | Concurrent producer/consumer stress test; overrun behaviour |
| Unit | Chunk writer alignment | Synthetic sine/click tracks with known offsets → verify sample alignment |
| Unit | Provider adapters | `URLProtocol` stubs with recorded responses (success, 401, 429, malformed JSON, SSE stream) |
| Unit | Summary schema validation & map-reduce | Golden transcripts → assert structure; mocked LLM |
| Unit | Echo de-dup | Fixture segment sets with overlapping duplicate text |
| Integration | Storage | In-memory GRDB; migrations; FTS search results |
| Integration | STT | Short fixture audio (EN + BN) through WhisperKit small → WER sanity threshold |
| Manual matrix | Real calls | Teams / Zoom / WhatsApp × headphones / speakers / AirPods switch / mute 5 min / app crash / sleep — checklist per release |
| Acceptance | Feature Spec §14 | Each criterion mapped to a manual or automated test |

CI (optional for a personal project): GitHub Actions macOS runner — build + unit tests on every push.

---

## 18. Performance budget

| Area | Budget | Approach |
|---|---|---|
| Idle monitoring | < 1% CPU, < 80 MB RAM | Event-driven listeners, no polling |
| Recording | < 5% CPU (M1) | Native format capture, AAC hardware encoder, 100 ms writer cadence |
| Memory while recording | < 200 MB | Pre-allocated ring buffers (~46 MB), streaming encode |
| Transcription | ≤ 0.3× RT (turbo, M1) | VAD skipping, ANE via Core ML, one job at a time |
| App launch | < 1 s to menu bar | Lazy model loading |
| Disk | ~30 MB/h per track (64 kbps) + mixed | Retention policy deletes audio after N days |

---

## 19. Delivery plan

### 19.1 Technical spikes (do first — they de-risk the whole design)

| Spike | Question | Exit criteria |
|---|---|---|
| S1 | Can process taps capture Teams, Zoom, WhatsApp call audio reliably (incl. helper processes)? | Clean remote audio in a test call for all 3 apps; no other-app audio |
| S2 | Do the mic-in-use signals give clean start/end for each app (pre-join preview, mute, hold)? | Logged signal timelines for 5 call scenarios per app; tuned debounce/grace |
| S3 | WhisperKit speed & accuracy (English, Bengali, mixed) on your Mac | Real-time factor and subjective quality acceptable with turbo |
| S4 | Diarization quality on the system track (FluidAudio or alternative) | ≥ 80% correct speaker turns on a 3-person test call |
| S5 | Echo on speakers — is transcript-level de-dup enough? | Duplicate "Me" lines < 5% in speaker test |

### 19.2 Milestones (MVP)

| # | Milestone | Contents |
|---|---|---|
| M1 | Skeleton | Xcode project, packages, menu bar app, GRDB setup, settings shell, logging |
| M2 | Capture | MicCapture, ProcessTapCapture, ring buffers, chunk writer, finalize job, manual Start/Stop |
| M3 | Detection | AudioProcessMonitor, rules engine, state machine, auto-record, notifications, crash recovery |
| M4 | Transcription | ModelManager (download on first use), WhisperKit engine, VAD, merge, echo de-dup, job queue |
| M5 | Summary | Keychain + Providers UI with Test connection, Anthropic/OpenAI/Gemini/OpenAI-compatible/Ollama adapters, schema, map-reduce |
| M6 | Library & detail | Session list, search (FTS5), player + transcript sync, summary/action items, Markdown/TXT export |
| M7 | Hardening | Onboarding & permissions, diagnostics, disk guard, retention, manual test matrix, acceptance criteria |

Phase 2/3 items (live transcript, browser detection, diarization UI, cloud STT, templates editor, Ask, calendar, PDF/DOCX/SRT, integrations, encryption at rest) slot in after M7 without architectural change.

---

## 20. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Meeting apps change helper processes/bundle IDs | Detection or capture breaks after an app update | Rules in JSON; prefix matching; detection reason logs; Diagnostics "test call" |
| Process tap API behaviour changes in new macOS | Capture breaks | ScreenCaptureKit fallback path behind the same `SystemAudioCapture` protocol |
| App keeps mic open outside calls (pre-join preview, background) | False recordings | Per-app debounce; require output activity for some apps; Discard; per-app Ask mode |
| Long local transcription drains battery | Poor UX on laptop | Defer on battery; smaller model option; cloud STT option |
| Bengali/code-switched accuracy | Lower transcript quality | Spike S3; allow cloud STT per app/language |
| LLM structured output inconsistencies across providers | Broken summary rendering | Schema validation + retry + Markdown fallback |

---

## 21. Open technical questions

1. Should the mic and process tap share **one aggregate device** (single clock, perfect alignment) instead of separate AVAudioEngine + tap? Simpler alignment vs. harder device-switch handling — decide after S1.
2. Keep 30 s `.m4a` chunks or switch to a crash-tolerant **CAF** container (no rotation needed)? Decide during M2.
3. Diarization library choice (FluidAudio vs. alternatives) — decide after S4.

---

## Changelog

- **v0.2 (2026-10-14)** — Applied Sprint 0 spike findings: detection uses process-list listener + 1 s poll (TD-3); verified bundle prefixes & helper processes; CATapDescription via ObjC shim; tap format, start-up gap, per-app silence behaviour.
- **v0.1 (2026-10-13)** — Initial technical design based on Feature Spec v0.2; local model download-on-first-use adopted (TD-5).
