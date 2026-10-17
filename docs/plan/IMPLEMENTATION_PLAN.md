# EchoMinutes — Sprint-wise Technical Implementation Plan

| Field | Value |
|---|---|
| Product | EchoMinutes (personal macOS utility) |
| Document | Implementation plan v0.2 |
| Based on | [FEATURE_SPEC.md](FEATURE_SPEC.md) v0.2 · [TECHNICAL_DESIGN.md](TECHNICAL_DESIGN.md) v0.1 |
| Owner | Tanim Kabir |
| Date | 2026-10-14 |
| Status | Draft |

---

## 1. Planning assumptions

| Item | Assumption (adjust if different) |
|---|---|
| Team | 1 developer (Tanim) + AI coding assistant |
| Sprint length | **1 week** (Mon–Sun) |
| Capacity | **~25 focused hours / sprint** (side project); estimates below are in hours and include tests |
| Start | Sprint 0 starts **Mon 2026-10-19** |
| Hardware | Apple Silicon Mac, macOS 14.4+ (ideally latest macOS), Xcode latest stable |
| Accounts | Apple Developer account (stable signing identity), at least one LLM API key, test accounts on Teams / Zoom / WhatsApp + a second device/person to make test calls |
| Scope | Sprints 0–12 = **MVP v1.0** (Feature Spec §13 Phase 1). Sprints 13–18 = Phase 2 (**v1.5**), 19–24 = Phase 3 (**v2.0**) — see §5 |
| Tracking | One checklist item per task ID below (GitHub Issues / Jira / TASKS.md) |

**Estimate legend:** each task row lists effort in hours. Each sprint totals ≤ ~25 h with ~10–15% buffer left for bugs and surprises.

**Definition of Done (every task):**
- Code compiles with Swift 6 strict concurrency, no warnings in new code.
- Unit tests for logic (state machines, parsers, adapters, repositories).
- Logged with the correct `os.Logger` category; no secrets in logs.
- Manually verified on your Mac; notes added to the sprint log.
- Merged to `main` with a short descriptive commit.

---

## 2. Roadmap at a glance

| Sprint | Dates (2026) | Theme | Milestone | Key output |
|---|---|---|---|---|
| S0 | Oct 19 – Oct 25 | Setup + capture & detection spikes | Spikes S1, S2 | Proof that Teams/Zoom/WhatsApp audio can be captured & detected |
| S1 | Oct 26 – Nov 1 | STT, diarization, echo spikes | Spikes S3–S5 | Engine choices locked; design doc updated |
| S2 | Nov 2 – Nov 8 | App skeleton & storage | M1 | Menu bar app, packages, DB + migrations, Keychain, settings shell |
| S3 | Nov 9 – Nov 15 | Audio capture core | M2 (1/2) | Mic + process-tap capture into ring buffers with level meters |
| S4 | Nov 16 – Nov 22 | Recording to disk | M2 (2/2) | Chunked AAC files, finalize job, manual record, crash recovery |
| S5 | Nov 23 – Nov 29 | Auto-detection | M3 (1/2) | Process monitor, rules engine, state machine (unit-tested) |
| S6 | Nov 30 – Dec 6 | Auto-record end-to-end | M3 (2/2) | Calls auto-recorded with pre-roll; notifications; Discard |
| S7 | Dec 7 – Dec 13 | Local transcription | M4 (1/2) | Model download, WhisperKit engine, VAD, job queue |
| S8 | Dec 14 – Dec 20 | Transcript quality | M4 (2/2) | Merge, "Me/Others", diarization, echo de-dup, persisted transcript |
| S9 | Dec 21 – Dec 27 | LLM providers & keys | M5 (1/2) | Providers UI, Keychain, Anthropic/OpenAI/Gemini/compat/Ollama adapters |
| S10 | Dec 28 – Jan 3 | Summaries | M5 (2/2) | Schema-validated summary + action items, map-reduce, cost |
| S11 | Jan 4 – Jan 10 | Library & session detail | M6 | Library, search, player synced with transcript, export |
| S12 | Jan 11 – Jan 17 | Onboarding & hardening → **v1.0** | M7 | Onboarding, diagnostics, retention, test matrix, acceptance sign-off |

> Holiday weeks (S9–S10) may run at lower capacity — slip the plan by a week rather than cutting tests.

### 2.1 Dependency chain

```
S0 spikes ─▶ S2 skeleton ─▶ S3 capture ─▶ S4 to-disk ─▶ S5/S6 detection ─┐
S1 spikes ─────────────────────────────────────────────▶ S7/S8 STT ─────┼─▶ S10 summary ─▶ S11 UI ─▶ S12 release
                         S2 storage/keychain ─▶ S9 providers ──────────┘
```

The critical path is **capture → detection → transcription**. If a spike fails, re-plan before S3.

---

## 3. Sprint details

### Sprint 0 — Setup + capture & detection spikes (Oct 19 – Oct 25)

**Goal:** prove the two riskiest assumptions: (1) process taps capture clean call audio for Teams, Zoom, WhatsApp; (2) Core Audio process signals reliably show call start/end.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-001 ✅ | Dev environment | Install latest Xcode, create git repo, `.gitignore`, README, branch strategy (`main` + short feature branches) | 1 | — |
| EM-002 ✅ | Signing identity | Create/confirm Apple Development certificate; note team ID; confirm TCC prompts persist across rebuilds with a stable identity | 1 | EM-001 |
| EM-003 ✅ | Spike project | Throwaway Xcode command-line/menu app `SpikeLab` (not production code), Hardened Runtime, `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription` | 1 | EM-002 |
| EM-004 ✅ | Spike S1a: list audio processes | Enumerate `kAudioHardwarePropertyProcessObjectList`; print PID, bundle ID, `IsRunningInput/Output` live; observe changes with property listeners | 3 | EM-003 |
| EM-005 ✅ | Spike S1b: process tap capture | `CATapDescription(stereoMixdownOfProcesses:)` → `AudioHardwareCreateProcessTap` → private aggregate device → IOProc → write WAV. Test with Music app first | 5 | EM-004 |
| EM-006 ✅ | Spike S1c: real call capture | Capture Teams, Zoom, WhatsApp calls (test call with a second device). Record which helper processes carry audio; confirm Spotify playing at same time is **not** captured | 4 | EM-005 |
| EM-007 | Spike S2: detection timelines | **Automated:** background logger (`passive/install.sh`) records mic/output events during real meetings for a few days; `passive/calls.py` derives per-app sessions, short false-start uses, in-call gaps → debounce/grace. Manual `scenario.sh` only for targeted checks | 5 | EM-004 |
| EM-008 ✅ | Spike findings write-up | `docs/spikes/S1-S2.md`: per-app bundle IDs/helpers, recommended debounce/grace, quirks, go/no-go. Update `DetectionRules.json` draft | 2 | EM-006, EM-007 |
| | **Sprint total** | | **22** | |

**Exit criteria:** clean remote audio WAV for all 3 apps; signal timelines show a usable start/end pattern; go/no-go recorded. **If S1 fails for an app** → prototype ScreenCaptureKit audio fallback in S1 before proceeding.

---

### Sprint 1 — STT, diarization & echo spikes (Oct 26 – Nov 1)

**Goal:** lock the transcription/diarization engines and echo strategy with real measurements.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-010 | Test audio corpus | Record fixtures from S0: 3 × 10-min calls (EN, BN, mixed EN/BN), one 3-person call, one on speakers (echo). Store outside repo; add 30-s clips to `Tests/Fixtures` | 2 | EM-006 |
| EM-011 | Spike S3a: WhisperKit setup | Add WhisperKit to SpikeLab; download models (base, small, large-v3-turbo); transcribe a WAV | 3 | EM-003 |
| EM-012 | Spike S3b: benchmark | Measure real-time factor, peak RAM, first-load (Core ML specialization) time; subjective quality EN/BN/mixed; with and without VAD | 4 | EM-010, EM-011 |
| EM-013 | Spike S3c: cloud comparison | Run same clips through one cloud STT (e.g., OpenAI transcription) for a quality baseline, esp. Bengali | 2 | EM-010 |
| EM-014 | Spike S4: diarization | Try FluidAudio (Core ML diarization) on the 3-person system-track clip; measure speaker-turn accuracy (target ≥ 80%); note an alternative if it fails | 5 | EM-010 |
| EM-015 ✅ | Spike S5: echo on speakers | Transcribe mic + system tracks of the speaker recording; prototype text-similarity + RMS de-dup; measure duplicate rate (target < 5%) | 4 | EM-012 |
| EM-016 ✅ | Aggregate-device question | Quick test: mic + tap in **one** aggregate device vs separate AVAudioEngine; decide (Tech Design §21 Q1) | 2 | EM-005 |
| EM-017 | Update technical design | Record decisions (default model, diarizer, echo approach, aggregate choice) in `TECHNICAL_DESIGN.md` §2/§21; changelog | 1 | all above |
| | **Sprint total** | | **23** | |

**Exit criteria:** default local model chosen with measured speed; diarizer decided (or "Others" only for MVP); echo approach confirmed; design doc updated.

---

### Sprint 2 — App skeleton & storage — M1 (Nov 2 – Nov 8)

**Goal:** production project structure with persistence, Keychain and an empty but navigable UI.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-020 ✅ | Xcode project | `EchoMinutes` app target, bundle ID `com.tanimkabir.echominutes`, `LSUIElement=YES`, Hardened Runtime, entitlements (`audio-input`), Info.plist usage strings, Swift 6 strict concurrency | 2 | S0 |
| EM-021 ✅ | Local Swift packages | Create `EMCore, EMDetection, EMAudio, EMSession, EMStorage, EMTranscription, EMSummarization, EMJobs, EMExport, EMUI` with test targets; wire into app | 2 | EM-020 |
| EM-022 ✅ | EMCore models | `SessionID`, `Session`, `SessionStatus`, `TrackKind`, `Speaker`, `TranscriptSegment`, `Summary`, `ActionItem`, `Bookmark`, `AppRule`, `ProviderID`, error types, injectable `Clock` | 3 | EM-021 |
| EM-023 ✅ | Database & migration v1 | GRDB `DatabasePool`, WAL, migration v1 = full schema from Tech Design §11.2 incl. `search_fts` | 3 | EM-022 |
| EM-024 ✅ | Repositories | `SessionRepository`, `TranscriptRepository`, `SummaryRepository`, `JobRepository`, `SettingsRepository`; FTS index maintenance; unit tests with in-memory DB | 4 | EM-023 |
| EM-025 ✅ | FileStore | App Support paths, per-session folder create/delete, `0700` perms, free-space query helper | 2 | EM-021 |
| EM-026 ✅ | KeychainStore | set/get/delete per `ProviderID`, `WhenUnlockedThisDeviceOnly`; unit tests (keychain test service name) | 2 | EM-022 |
| EM-027 ✅ | Logging | `Log` facade over `os.Logger` with categories; secret-redaction helper + test | 1 | EM-021 |
| EM-028 ✅ | Menu bar shell | `MenuBarExtra` with status text, Open Library, Settings, Quit; `AppState` (@Observable) | 2 | EM-020 |
| EM-029 ✅ | Main window & Settings shell | `NavigationSplitView` with empty list; `Settings` scene with all tabs as placeholders | 2 | EM-028 |
| EM-030 ✅ | Launch at login | `SMAppService.mainApp` toggle in General settings | 1 | EM-029 |
| | **Sprint total** | | **24** | |

**Demo:** app launches to menu bar, opens empty library and settings; DB file created; tests green.

---

### Sprint 3 — Audio capture core — M2 part 1 (Nov 9 – Nov 15)

**Goal:** production-quality capture of mic and meeting-app audio into lock-free ring buffers.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-040 ✅ | SPSCRingBuffer | Pre-allocated Float32 ring with `swift-atomics` head/tail; write (RT-safe), read, `keepLast(seconds)`, overrun counter; stress test with concurrent producer/consumer | 4 | EM-021 |
| EM-041 ✅ | Process resolver | Map `WatchedApp` → all audio process object IDs (bundle prefix + PID→responsible app fallback; exclude own PID) | 2 | EM-004 findings |
| EM-042 ✅ | ProcessTapCapture | Production version of spike: create tap + private aggregate device, IOProc copies to ring, read tap format, clean teardown; `SystemAudioCapture` protocol | 5 | EM-040, EM-041 |
| EM-043 | Tap rebuild on new helper | Listen for process-list changes during capture; rebuild tap with new PID set; write `tapRebuilt` marker | 2 | EM-042 |
| EM-044 ✅ | MicCapture (in the same aggregate device, per EM-016) | `AVAudioEngine` input tap → ring; handle `AVAudioEngineConfigurationChange` + default-input change → restart, `deviceChanged` marker | 3 | EM-040 |
| EM-045 | ScreenCaptureKit fallback (stub) | `SCStreamSystemAudioCapture` conforming to `SystemAudioCapture`; enabled only if S0 showed need — otherwise interface + TODO | 2 | EM-042 |
| EM-046 ✅ | RecordingService API | Actor: `startCapture(app:)`, `beginPersisting()`, `pause/resume`, `stop()`, `levels: AsyncStream<Levels>` | 3 | EM-042, EM-044 |
| EM-047 ✅ | Level meters | RMS per 100 ms per track computed on writer queue → stream to UI; silent-track (> 60 s) warning event | 2 | EM-046 |
| | **Sprint total** | | **23** | |

**Demo:** debug menu "Start capture: Zoom" shows two live level meters during a test call; no audio glitches; overrun counter = 0.

---

### Sprint 4 — Recording to disk — M2 part 2 (Nov 16 – Nov 22)

**Goal:** a manual recording produces aligned, crash-safe audio files ready for transcription.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-050 ✅ | ChunkWriter | Serial queue drains rings every 100 ms; `AVAudioConverter` → 48 kHz mono; AAC 64 kbps; rotate 30-s `.m4a` chunks per track | 5 | EM-046 |
| EM-051 ✅ | Timeline alignment | Store first-sample host time per chunk; insert silence for gaps so tracks share t=0; unit test with synthetic offset tracks | 3 | EM-050 |
| EM-052 ✅ | Session manifest | `manifest.json` (tracks, chunks, anchors, markers, health metrics) written atomically on each rotation | 2 | EM-050 |
| EM-053 ✅ | Pre-roll drain | Candidate mode keeps last N s in ring only; `beginPersisting()` drains pre-roll then continues live | 2 | EM-050 |
| EM-054 ✅ | FinalizeAudioJob | Concatenate chunks (`AVMutableComposition`, passthrough) → `mic.m4a`, `system.m4a`; mixdown `mixed.m4a`; waveform peaks `waveform.bin`; verify durations; delete chunks | 4 | EM-052 |
| EM-055 ✅ | Manual recording UI | Menu bar Start (pick app) / Pause / Stop / Discard; elapsed timer; session row created with status transitions | 3 | EM-054 |
| EM-056 ✅ | Crash recovery | On launch: sessions in `recording/paused/finalizing` → `interrupted`; "Recover" runs FinalizeAudioJob on existing chunks | 2 | EM-054 |
| EM-057 ✅ | Disk guard | Check before rotation: warn < 2 GB, safe-stop < 500 MB with notification | 1 | EM-050 |
| EM-058 ✅ | Manual test pass | Record 3 real calls (each app); kill app mid-call → recover; check sync by clapping test | 2 | all above |
| | **Sprint total** | | **24** | |

**Demo:** manual recording of a Teams call → playable `mixed.m4a` with both voices in sync; force-quit loses ≤ 30 s.

---

### Sprint 5 — Auto-detection engine — M3 part 1 (Nov 23 – Nov 29)

**Goal:** fully unit-tested detection pipeline producing correct meeting start/end signals.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-060 ✅ | DetectionRules.json | Bundled rules (Teams, Zoom, WhatsApp + P1 apps) from spike findings; loader + user overrides from `app_rules` table | 2 | EM-008, EM-024 |
| EM-061 ✅ | AudioProcessMonitor | Actor with process-list + 1 s poll (per-process listeners don't fire on macOS 26) → `AsyncStream<ActivitySnapshot>`; debug Detection Monitor window | 4 | EM-041 |
| EM-062 ✅ | AppWatcher | `NSWorkspace` launch/terminate + sleep/wake notifications → events | 1 | EM-021 |
| EM-063 ✅ | Activity → MeetingSignal | Attribute activity to watched apps (prefix match, own-PID exclusion), emit `micStarted/micStopped/outputChanged/appTerminated/systemWillSleep` | 3 | EM-060, EM-061 |
| EM-064 ✅ | RulesEngine | Modes auto/ask/never, private hours, per-app debounce/grace, concurrent-call policy | 3 | EM-063 |
| EM-065 ✅ | SessionCoordinator state machine | Idle → Candidate → Recording ⇄ Paused → Finalizing; Discard; timers via injected `Clock` | 5 | EM-064 |
| EM-066 ✅ | State machine test suite | Scripted scenarios: voice note (ignored), normal call, mute 5 min, mic off but output on, app crash, sleep, two apps at once, manual override | 4 | EM-065 |
| EM-067 ✅ | Detection reason logging | Reason codes (`IGNORED_DEBOUNCE`, `STARTED_AUTO`, `ENDED_GRACE` …) logged per decision | 1 | EM-065 |
| | **Sprint total** | | **23** | |

**Demo:** test suite green; debug window shows live signals and the state machine reacting to a real call (no recording yet).

---

### Sprint 6 — Auto-record end-to-end — M3 part 2 (Nov 30 – Dec 6)

**Goal:** joining a call in Teams/Zoom/WhatsApp records automatically, with no prompt, and stops when the call ends.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-070 ✅ | Wire coordinator ↔ recording | Candidate → `startCapture`; Recording → `beginPersisting`; Finalizing → `stop` + enqueue jobs; Discard → delete | 3 | EM-055, EM-065 |
| EM-071 ✅ | Notifications | `UNUserNotificationCenter` categories: RECORDING_STARTED (Stop, Discard), SWITCH_APP, RECORDING_SAVED; action handlers | 3 | EM-070 |
| EM-072 ✅ | Menu bar states | Idle / Monitoring / Recording (red + timer) / Processing icons; dropdown reflects current session | 2 | EM-070 |
| EM-073 ✅ | Mini widget | Floating `NSPanel`: timer, two meters, bookmark, stop; toggle in settings | 3 | EM-047, EM-072 |
| EM-074 ✅ | Bookmarks & hotkeys | Carbon global hotkeys (no extra dependency): ⌃⌥⌘R start/stop, ⌃⌥⌘B bookmark, ⌃⌥⌘W widget; bookmarks saved with `at_ms`, shown as jump buttons in the player | 2 | EM-073 |
| EM-075 ✅ | Detection settings UI | Watched apps list with per-app mode (Auto default / Ask / Never), debounce/grace overrides, private hours ("Add app…" picker deferred to Phase 2 browser support) | 4 | EM-060 |
| EM-076 ✅ | Ask mode | Candidate waits for notification response; keeps 60 s in ring; default action after 20 s | 2 | EM-071 |
| EM-077 ✅ | Real-call tuning | 3 calls per app incl. mute/rejoin; tune debounce/grace in rules JSON; fix false starts. Checklist: `docs/testing/EM-077-real-call-tuning.md`, report: `scripts/detection-report.py`. Follow-up: 15-min+ real-call soak + per-app timing review | 4 | all above |
| | **Sprint total** | | **23** | |

**Demo:** join a Zoom call → recording starts automatically within debounce + 1 s with pre-roll; leave → stops within grace + 2 s; WhatsApp set to Never is ignored.

---

### Sprint 7 — Local transcription — M4 part 1 (Dec 7 – Dec 13)

**Goal:** recordings automatically turn into raw transcripts via a resilient job queue.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-080 ✅ | JobQueue | DB-backed actor; enqueue/claim/complete/fail; resume at launch; concurrency limits (1 STT, 2 LLM); exponential backoff | 4 | EM-024 |
| EM-081 ✅ | Pipeline chaining | `finalizeAudio → transcribe → summarize`; session status updates per stage | 1 | EM-080, EM-054 |
| EM-082 ✅ | TranscriptionEngine protocol | `prepare`, `transcribe(file:options:progress:)`, `RawSegment`, `STTOptions` | 1 | EM-022 |
| EM-083 ✅ | ModelManager | Download on first use (WhisperKit downloader) with progress/resume; list installed, size, delete; "Optimizing model…" first-load state | 4 | EM-011 |
| EM-084 ✅ | WhisperKitEngine | Load model, transcribe file, language auto/forced, custom vocabulary prompt, segment timestamps, cancellation | 4 | EM-082, EM-083 |
| EM-085 ✅ | VAD | Speech-region detection to skip silence; map region offsets back to session timeline | 3 | EM-084 |
| EM-086 ✅ | Hallucination guard | Drop high no-speech-prob segments and repeated n-gram loops; unit tests with fixtures | 2 | EM-084 |
| EM-087 ✅ | Transcription settings UI | Engine (local), model picker + download button/progress, language, custom vocabulary | 2 | EM-083 |
| EM-088 ✅ | Power policy | Defer heavy STT on battery < 20% / Low Power Mode unless "Transcribe now" | 1 | EM-080 |
| | **Sprint total** | | **22** | |

**Demo:** after a call ends, both tracks transcribe automatically with progress shown; quitting mid-job resumes on relaunch.

---

### Sprint 8 — Transcript quality — M4 part 2 (Dec 14 – Dec 20)

**Goal:** a clean, speaker-labelled transcript stored and searchable.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-090 ✅ | Track merge | Merge mic + system segments by `start_ms`; mic → speaker "Me" (name from settings) | 2 | EM-084 |
| EM-091 ✅ | Diarizer integration | Chosen diarizer (S4) on `system.m4a` → turns; assign Speaker 1..N by max overlap; fallback to "Others" on failure | 5 | EM-014, EM-090 |
| EM-092 ✅ | Echo detection | Detect built-in speakers output (transport type/data source) → `echo_risk` flag on session | 2 | EM-044 |
| EM-093 ✅ | Echo de-dup | Pulled into S7 after the first real transcript: word containment ≥ 0.6 + time overlap (±3 s) → drop duplicate mic segments, set `echo_risk`; Teams speaker-test fixture. RMS ratio not needed so far | 3 | EM-015, EM-090 |
| EM-094 ✅ | Persist transcript | Write segments + speakers in one transaction; update FTS; status `summarizing` or `ready` | 2 | EM-090 |
| EM-095 ✅ | Speaker rename | Rename updates `speakers.display_name` (UI hook ready for S11) | 1 | EM-094 |
| EM-096 ⏸ | Cloud STT engine (optional) — deferred until EM-097 shows Bengali needs it | `OpenAITranscriptionEngine` (chunk upload ≤ size limit, timestamps) — only if S1 showed Bengali needs it; else defer to Phase 2 | 4 | EM-082, EM-026 |
| EM-097 🔄 | Quality check (open: needs real 3-person / Bengali / speakers calls) | Run corpus through full pipeline; record WER-style notes, duplicate rate, speaker accuracy. Checklist: `docs/testing/EM-097-transcript-quality.md` | 3 | all above |
| | **Sprint total** | | **22** | |

**Demo:** 3-person Zoom call → transcript with "Me", "Speaker 1", "Speaker 2" and timestamps; no echo duplicates on speakers test.

---

### Sprint 9 — LLM providers & API keys — M5 part 1 (Dec 21 – Dec 27)

**Goal:** user can enter keys in the UI, test them, and the app can call every MVP provider.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-100 ✅ | LLMProvider protocol & types | `LLMRequest/Response/Message`, `ProviderID`, error taxonomy (invalidKey, rateLimited, quota, network, server, badResponse) | 2 | EM-022 |
| EM-101 ✅ | HTTPClient | URLSession wrapper, timeouts, JSON coding, SSE stream parser, retry hints from `retry-after`; URLProtocol test stubs | 3 | EM-100 |
| EM-102 ✅ | Anthropic adapter | Messages API, headers, structured output, token usage, list models, test connection | 3 | EM-101 |
| EM-103 ✅ | OpenAI adapter | Chat completions with `json_schema`, usage, list models; Azure OpenAI variant (endpoint/deployment/api-version) | 3 | EM-101 |
| EM-104 ✅ | Gemini adapter | `generateContent` with `responseSchema`, usage, list models | 2 | EM-101 |
| EM-105 ✅ | OpenAI-compatible + OpenRouter + Ollama | Custom base URL adapter; Ollama `/api/chat` with `format` schema; localhost-only http allowed | 3 | EM-103 |
| EM-106 ✅ | Providers settings UI | Per provider: enable, masked key field, model dropdown (fetched) + free text, base URL, **Test connection** with clear result; Remove key; Touch ID reveal | 5 | EM-026, EM-102…105 |
| EM-107 ✅ | Default provider selection | Separate defaults for transcription & summary; fallback banner when key missing | 1 | EM-106 |
| | **Sprint total** | | **22** | |

**Demo:** paste a Claude key → Test connection succeeds and lists models; invalid key shows a friendly error; key visible only in Keychain Access.

---

### Sprint 10 — Summaries — M5 part 2 (Dec 28 – Jan 3)

**Goal:** every finished meeting gets a validated summary with decisions and action items.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-110 ✅ | Summary schema & validator | `SummarySchema` JSON + lightweight validator; decode into `SummaryModel` | 2 | EM-100 |
| EM-111 ✅ | Prompt builder | Transcript formatting `[mm:ss] Speaker: text`, delimiters (prompt-injection guard), template system prompt, metadata | 2 | EM-094 |
| EM-112 ✅ | Built-in templates | General, Stand-up, 1:1, Client call, Interview, Sprint planning, Retro (JSON); auto-rule matching | 3 | EM-111 |
| EM-113 ✅ | Token estimate & map-reduce | Context budget per model; chunk on segment boundaries with overlap; map prompts → reduce prompt | 4 | EM-111 |
| EM-114 ✅ | SummarizeJob | Call provider, validate, retry once with errors, Markdown fallback, persist summary + action items, auto-title | 3 | EM-110, EM-113, EM-080 |
| EM-115 ✅ | Error handling | 401/403 → failed with "Fix key" action; 429/5xx/network → backoff; transcript always preserved | 2 | EM-114 |
| EM-116 ✅ | Cost tracking | `Pricing.json`, cost per summary, monthly total in settings | 2 | EM-114 |
| EM-117 ✅ | Regenerate & local-only | Regenerate with another template/model (keeps history, `is_current`); per-app `local_only` forces Ollama/skip | 2 | EM-114 |
| EM-118 🔄 | Summary quality pass (open: real calls × 2 providers) | Run all corpus transcripts through 2 providers; tune prompts | 3 | all above |
| | **Sprint total** | | **23** | |

**Demo:** call ends → transcript → summary with TL;DR, decisions and action items appears automatically; notification "Summary ready".

---

### Sprint 11 — Library & session detail — M6 (Jan 4 – Jan 10)

**Goal:** browse, search, listen, read and export meetings.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-120 ✅ | Library list | Sessions grouped Today / This week / Earlier; app icon, duration, status badge; GRDB `ValueObservation` | 3 | EM-024 |
| EM-121 ✅ | Filters & search | App, date range, has action items; FTS5 search with `snippet()` highlights and jump-to-timestamp | 3 | EM-120 |
| EM-122 ✅ | Audio player | AVAudioPlayer on `mixed.m4a`, speed, ±15 s, “Listen to: Everyone / Only me / Only the call” (keeps the balanced levels, unlike muting raw tracks); waveform canvas from `waveform.bin` with bookmarks | 4 | EM-054 |
| EM-123 ✅ | Transcript view | Lazy list, current-segment highlight (binary search), click-to-seek, inline edit, speaker rename sheet | 4 | EM-122, EM-095 |
| EM-124 ✅ | Summary & Action Items tabs | Render summary sections; checkable/editable action items; copy as checklist; regenerate menu | 3 | EM-114 |
| EM-125 ✅ | Notes tab | Markdown notes per session, autosave | 1 | EM-120 |
| EM-126 ✅ | Export | Markdown + TXT (sections selectable), audio export, copy summary to clipboard | 3 | EM-124 |
| EM-127 ✅ | Delete flows | Delete session / delete audio only (keep text), confirmation, FTS cleanup | 1 | EM-120 |
| | **Sprint total** | | **22** | |

**Demo:** search a word from last week's call → open session → click result → audio plays at that moment with the line highlighted; export to Markdown.

---

### Sprint 12 — Onboarding, hardening & v1.0 release — M7 (Jan 11 – Jan 17)

**Goal:** a reliable daily-driver build that passes all MVP acceptance criteria.

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-130 ✅ | Onboarding flow | Welcome + consent notice → permissions checklist → local/cloud choice + key test → apps to watch (Auto default) → model download → test call | 4 | S6–S10 |
| EM-131 ✅ | Permission checks & deep links | Mic status, notification status, system-audio functional test (test tone), System Settings deep links | 2 | EM-130 |
| EM-132 ✅ | Diagnostics page | Re-check permissions, 5-s audio test both tracks, detection live view, export redacted log bundle | 3 | EM-067 |
| EM-133 ✅ | Retention & storage | Keep audio N days — 7 / 30 / 90 days, 6 months, 1 year (transcript kept), storage usage view, cleanup job | 2 | EM-080 |
| EM-134 ✅ | Consent reminder | Optional notification with "Copy consent message" on recording start | 1 | EM-071 |
| EM-135 | Performance check | Targets: idle CPU < 1%, recording < 5%, memory < 200 MB — measure with `scripts/perf-check.sh` (idle / recording); Instruments for hotspots | 3 | — |
| EM-136 | Manual test matrix | Matrix in `docs/testing/EM-136-test-matrix.md` | 4 | all |
| EM-137 | Acceptance sign-off | Verify Feature Spec §14 criteria 1–10; record results in `docs/acceptance-v1.md` | 2 | EM-136 |
| EM-138 | Release build | `scripts/release.sh 1.0.0`: tests → Release build → verify → install to /Applications → tag. Developer ID + notarization only needed to share the app | 2 | EM-137 |
| | **Sprint total** | | **23** | |

**Exit criteria (MVP done):** all 10 acceptance criteria pass; app used for one full week of real meetings with no lost recordings.

---

## 4. Effort summary (MVP)

| Sprint | Theme | Hours |
|---|---|---|
| S0 | Setup + capture/detection spikes | 22 |
| S1 | STT/diarization/echo spikes | 23 |
| S2 | Skeleton & storage | 24 |
| S3 | Audio capture core | 23 |
| S4 | Recording to disk | 24 |
| S5 | Detection engine | 23 |
| S6 | Auto-record E2E | 23 |
| S7 | Local transcription | 22 |
| S8 | Transcript quality | 22 |
| S9 | LLM providers & keys | 22 |
| S10 | Summaries | 23 |
| S11 | Library & detail | 22 |
| S12 | Onboarding & release | 23 |
| **Total** | **13 sprints (~13 weeks)** | **~296 h** |

At ~25 h/week this lands **v1.0 around mid-January 2027**. At full-time pace (~35 productive h/week) it compresses to ~9 weeks.

**Earliest useful build:** end of **S8** (auto-record + transcript) — you can start using it for real meetings and paste transcripts into an LLM manually while S9–S12 finish.

---

## 5. Phase 2 & 3 — sprint details (post-MVP)

Same rules as Sprints 0–12: 1-week sprints, ~25 h capacity, estimates in hours incl. tests, Definition of Done from §1. Task IDs continue the pattern (S13 → EM-14x, S14 → EM-15x, …). Dates follow the original calendar; shift them to wherever v1.0 actually lands.

### 5.1 Roadmap at a glance

| Sprint | Dates (2027) | Theme | Phase | Key output |
|---|---|---|---|---|
| S13 | Jan 18 – Jan 24 | Live transcript | 2 | Near-real-time transcript in the mini-widget (≤ 5 s latency), replaced by the final pass |
| S14 | Jan 25 – Jan 31 | Browser meetings | 2 | Google Meet / Teams Web / Zoom Web auto-detected; "Browser is using mic — record?" fallback |
| S15 | Feb 1 – Feb 7 | More apps & cloud STT | 2 | Slack Huddles, FaceTime, Webex; Deepgram / AssemblyAI / OpenAI engines; per-app engine |
| S16 | Feb 8 – Feb 14 | Templates & Ask | 2 | Template editor with auto-rules; Ask-the-meeting chat with `[mm:ss]` citations |
| S17 | Feb 15 – Feb 21 | Calendar & exports | 2 | Meetings titled from Calendar, attendees as speaker hints; PDF, DOCX, SRT, VTT export |
| S18 | Feb 22 – Feb 28 | Signal-level AEC | 2 → **v1.5** | NLMS echo canceller on the mic track before STT for speaker setups |
| S19 | Mar 1 – Mar 7 | Cross-meeting Q&A | 3 | "Ask all meetings" with citations to meeting + timestamp |
| S20 | Mar 8 – Mar 14 | Voice-print speakers | 3 | Recognise known people across meetings |
| S21 | Mar 15 – Mar 21 | Integrations I | 3 | Webhook, Slack, Notion, share sheet / Apple Notes |
| S22 | Mar 22 – Mar 28 | Integrations II | 3 | Confluence pages, Jira issues from action items |
| S23 | Mar 29 – Apr 4 | Encryption at rest | 3 | AES-GCM audio + encrypted database, key in Keychain |
| S24 | Apr 5 – Apr 11 | Bengali UI → **v2.0** | 3 | Full Bengali localisation |

**Already delivered in the MVP (not re-planned):** multi-speaker diarization + speaker rename (EM-095, EM-123), cost tracking (EM-116), built-in templates with auto-rule matching (EM-112), audio download (EM-126).

### 5.2 Before Sprint 13 (carry-overs)

| ID | Item | Why it matters for Phase 2 |
|---|---|---|
| EM-097 | Transcript quality on real 3-person / Bengali / speaker calls | Baseline that S15 (cloud STT) and S18 (AEC) are measured against |
| EM-118 | Summary quality pass, 2 providers | Baseline for S16 templates and Ask |
| EM-135 | Performance check | S13 adds a live model; needs the recording-only baseline first |
| EM-136–138 | Test matrix, acceptance, v1.0 tag | Phase 2 branches from a tagged, stable `main` |

---

### Sprint 13 — Live transcript (Jan 18 – Jan 24)

**Goal:** while recording, show what's being said within ~5 s, without hurting the recording; the final pass still produces the stored transcript (FR-STT-02/03, Tech Design §9.5).

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-140 🔄 | Spike: streaming latency (open: fill `docs/spikes/S13-live.md` on real calls) | WhisperKit `tiny`/`base`/`small` on 15-s windows, EN + BN: latency, CPU, accuracy vs final pass. Pick default live model; record in `docs/spikes/S13-live.md` | 3 | v1.0 |
| EM-141 ✅ | Live audio feed | `ChunkWriter` also pushes 16 kHz mono frames per track into a `LiveFeed` ring on its drain queue (no allocation; drops frames if the transcriber lags — recording never waits) | 3 | EM-140 |
| EM-142 ✅ | `LiveTranscriber` actor | Per track, 15-s sliding window with 5-s hop; VAD gate skips silence; commit a line once two consecutive passes agree (local-agreement), keep the tail as "tentative"; HallucinationGuard on output | 5 | EM-141 |
| EM-143 ✅ | Live model & power policy | Separate small model in `STTModelManager`; Settings ▸ Transcription "Live transcript" (off by default); pause on battery < 20% or thermal state ≥ serious, resume after | 2 | EM-142 |
| EM-144 ✅ | Mini-widget live view | Expandable panel: last ~6 lines, "Me" vs call colours, tentative text greyed, auto-scroll with "jump to live"; toggle in widget per spec §5.7 | 3 | EM-142 |
| EM-145 ✅ | Crash-safe live buffer | Committed lines appended to `live.jsonl` in the session folder; shown in session detail until the final transcript replaces it, then deleted | 2 | EM-142 |
| EM-146 ✅ | Live echo handling | Run `EchoDeduplicator` on committed windows so speaker setups don't show lines twice | 1 | EM-142 |
| EM-147 🔄 | Performance budget (open: `perf-check.sh 60 live` on a real call) | `scripts/perf-check.sh … live`: recording + live < 15% CPU, < 400 MB on M-series; recording-only numbers unchanged when live is off | 2 | EM-143 |
| EM-148 ✅ | Tests | Window/commit logic with a scripted engine (no model); feed back-pressure test; 3 real calls side by side with final pass | 2 | all above |
| | **Sprint total** | | **23** | |

**Demo:** Teams call → mini-widget shows both sides talking within ~5 s; after the call the session shows the final, higher-quality transcript.

---

### Sprint 14 — Browser meetings (Jan 25 – Jan 31)

**Goal:** Google Meet, Teams Web and Zoom Web are recorded like desktop apps; unknown browser calls get a one-tap prompt (Feature Spec §3.2, §15 edge case).

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-150 | Spike: window titles & audio processes | `SCShareableContent` titles for Chrome, Safari, Edge, Arc, Brave, Firefox incl. background tabs / other Spaces / minimised; AX API as fallback; which browser processes hold mic and output (renderer / audio service helpers) Built with `CGWindowListCopyWindowInfo` (sync, no prompt when not permitted) instead of SCShareableContent; verification sheet `docs/spikes/S14-browser.md`. | 3 | v1.0 |
| EM-151 | Screen Recording permission flow | Optional; requested only when browser detection is turned on; status + deep link in Permissions, Diagnostics and onboarding; detection degrades to the prompt when denied | 2 | EM-150 |
| EM-152 | `BrowserMatcher` | Only polls titles while a browser holds the mic (2-s throttle, cached); matches `titlePatterns` → platform (meet / teams-web / zoom-web) Built as `BrowserMeetingTracker` + `WebMeetingClassifier` (EMDetection). | 4 | EM-150 |
| EM-153 | Browser rules | `browsers` section in `DetectionRules.json` + `RuleSet` parsing; per-platform toggles in Settings ▸ Detection | 2 | EM-152 |
| EM-154 | State machine & capture | Browser meetings as virtual apps (`browser:meet` …) with own debounce/grace; capture taps the browser's audio processes found in EM-150; title change ≠ call end Ids `meet` / `teams-web` / `zoom-web` / `browser`; capture narrowed to the browser holding the mic. | 4 | EM-153 |
| EM-155 | "Browser is using mic — record?" | No matching title (or no permission) → notification with Record / Not now / Never for this browser; pre-roll kept while asking | 3 | EM-154 |
| EM-156 | Session title from tab | Clean tab title (strip "– Google Chrome", meeting codes) as the session title | 1 | EM-152 |
| EM-157 | Tests | Matcher unit tests with real title fixtures; state-machine cases (tab switch, two meetings, mic-only sites like dictation); manual matrix 3 platforms × 2 browsers | 4 | all above |
| | **Sprint total** | | **23** | |

**Demo:** join a Google Meet in Chrome → recording starts automatically and is titled from the tab; a browser voice call on an unknown site shows the prompt.

---

### Sprint 15 — More apps & cloud STT (Feb 1 – Feb 7)

**Goal:** detect three more call apps; offer cloud transcription where local quality isn't enough (esp. Bengali — resolves EM-096).

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-160 | Spike: Slack, FaceTime, Webex | Bundle IDs, which processes hold mic/output during a call (FaceTime → `avconferenced`), huddle vs regular call | 3 | v1.0 |
| EM-161 | Rules & real-call tuning | Add the three apps to `DetectionRules.json`; 3 calls each with the EM-077 checklist; tune debounce/grace; no false starts from Slack notifications / FaceTime ringing | 4 | EM-160 |
| EM-162 | Cloud STT base | Shared upload/retry/backoff, language hint, segment mapping to `RawSegment`; keys via Providers/Keychain; STT cost into cost tracking | 2 | — |
| EM-163 | `DeepgramEngine` | Pre-recorded API, utterances + word timestamps, language per session | 3 | EM-162 |
| EM-164 | `AssemblyAIEngine` | Upload + poll, timestamps, language detection | 3 | EM-162 |
| EM-165 | `OpenAITranscriptionEngine` | Chunked upload under the size limit with offset mapping (was EM-096) | 2 | EM-162 |
| EM-166 | Per-app engine choice | Settings ▸ Transcription: default engine + per-app override; `local_only` apps can never use cloud | 2 | EM-163 |
| EM-167 | Privacy disclosure | First use of a cloud engine shows what is uploaded and where; logged per session (`sttProvider`) | 1 | EM-166 |
| EM-168 | Tests & comparison | HTTP-mocked adapter tests from recorded fixtures; run EM-097 corpus through local vs each cloud engine, note WER/speed/cost | 3 | all above |
| | **Sprint total** | | **23** | |

**Demo:** a Bengali WhatsApp call transcribed with Deepgram per the per-app setting; Slack huddle auto-recorded.

---

### Sprint 16 — Templates & Ask (Feb 8 – Feb 14)

**Goal:** you can write your own summary templates and ask questions about a meeting with answers that link to the moment in the recording (FR-LLM-06, Tech Design §10.4–10.5).

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-170 | User templates storage | DB migration for user templates (same JSON shape as built-ins); "Duplicate" a built-in to customise it | 2 | v1.0 |
| EM-171 | Template editor | Settings ▸ AI Summary: name, focus prompt, sections; "Preview on a past meeting" runs it without saving | 4 | EM-170 |
| EM-172 | Auto-rules editor | Rules by app, title regex, weekday/time; ordered by priority; "Test against my last 20 meetings" | 3 | EM-170 |
| EM-173 | Import / export templates | JSON file, validated on import | 1 | EM-170 |
| EM-174 | Ask engine | Whole transcript in context, or FTS5/BM25 top-k segments for long meetings; answer must cite `[mm:ss]`; citations checked against real segment times | 4 | — |
| EM-175 | Ask tab | Chat in session detail; streams when the provider supports it; citations seek the player; suggested questions | 4 | EM-174 |
| EM-176 | Chat history & cost | Per-session chat stored in DB; cost per answer into cost tracking | 2 | EM-175 |
| EM-177 | Guards | Transcript delimited as data (prompt-injection guard); `local_only` meetings only use Ollama | 1 | EM-174 |
| EM-178 | Tests | Template CRUD/rules unit tests; Ask with scripted provider incl. bad citations | 2 | all above |
| | **Sprint total** | | **23** | |

**Demo:** "What did we decide about the release date?" → answer with `[12:40]` that jumps the player there.

---

### Sprint 17 — Calendar & exports (Feb 15 – Feb 21)

**Goal:** meetings named from your calendar and shareable in common formats (Feature Spec §5.8).

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-180 | Calendar permission | Optional EventKit read access from Settings / onboarding; never writes | 2 | v1.0 |
| EM-181 | Event matching | Event overlapping the call start (± 5 min); prefer the one whose meeting link matches the app; sets title, `calendarEventId`, attendees | 3 | EM-180 |
| EM-182 | Attendees as hints | Suggest attendee names in the speaker rename sheet; event title available to template auto-rules | 2 | EM-181 |
| EM-183 | Calendar settings | Choose calendars; ignore all-day and declined events | 1 | EM-180 |
| EM-184 | PDF export | Same sections as Markdown export, rendered to paginated PDF | 3 | — |
| EM-185 | DOCX export | Minimal OOXML writer (headings, lists, checkboxes, transcript table), zipped | 4 | — |
| EM-186 | SRT / VTT export | From transcript segments with speaker names | 2 | — |
| EM-187 | Export sheet | Format picker incl. new formats; export several meetings at once from the library | 2 | EM-184 |
| EM-188 | Tests | Event-matching cases; golden-file tests per export format; DOCX opens in Word/Pages | 3 | all above |
| | **Sprint total** | | **22** | |

**Demo:** a Zoom call during "Sprint planning" is titled from the calendar; exported as PDF and DOCX; SRT plays as subtitles.

---

### Sprint 18 — Signal-level AEC → v1.5 (Feb 22 – Feb 28)

**Goal:** remove the other people's voices from your mic track when you use speakers, before transcription (Tech Design §7.7 Phase 2).

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-190 | Offline prototype | Script on speaker-setup recordings: delay estimate + NLMS; measure echo reduction (ERLE) and speech damage | 4 | EM-097 corpus |
| EM-191 | Delay & drift estimation | Cross-correlation (GCC-PHAT) between call and mic tracks per block; track drift over long meetings | 3 | EM-190 |
| EM-192 | Echo canceller | Partitioned-block frequency-domain NLMS with Accelerate/vDSP; double-talk detector freezes adaptation while you speak | 6 | EM-191 |
| EM-193 | Pipeline integration | In finalize, when `echoRisk`: write `mic.aec.m4a`; transcription uses it; original kept for playback | 2 | EM-192 |
| EM-194 | Setting | Settings ▸ Recording ▸ Echo handling: "Remove echo from audio (beta)"; transcript de-dup stays on as a fallback | 1 | EM-193 |
| EM-195 | Quality evaluation | Duplicate rate and WER on speaker-setup corpus: off / de-dup / AEC / both | 3 | EM-193 |
| EM-196 | Tests | Synthetic echo with a known impulse response + delay; double-talk case; long-file drift case | 3 | EM-192 |
| | **Sprint total** | | **22** | |

**Exit criteria (v1.5):** live transcript, browser meetings, cloud STT, templates, Ask, calendar and new exports all shipped; duplicate rate on speaker calls < 2%; tag `v1.5.0`.

---

### Phase 3 sprints (S19 – S24)

Lighter detail — re-estimate at the start of each sprint.

#### Sprint 19 — Cross-meeting Q&A (Mar 1 – Mar 7)

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-200 | Chunking & index | Transcript chunks (~60 s, speaker-aware) with meeting id + time range; built in a background job, incremental | 4 | S16 |
| EM-201 | Embeddings | Local (`NLContextualEmbedding`) by default; provider embeddings optional; vectors in SQLite | 4 | EM-200 |
| EM-202 | Hybrid retrieval | FTS5/BM25 + vector similarity, date/app filters, re-rank | 4 | EM-201 |
| EM-203 | "Ask all meetings" window | Menu bar + library entry; answers cite `Meeting · [mm:ss]` and open that moment | 5 | EM-202 |
| EM-204 | Privacy & cost | `local_only` meetings never sent to cloud LLMs; cost per question | 2 | EM-203 |
| EM-205 | Tests | Retrieval quality on a 20-meeting fixture set; citation validity | 4 | all above |
| | **Sprint total** | | **23** | |

#### Sprint 20 — Voice-print speaker recognition (Mar 8 – Mar 14)

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-210 | Speaker embeddings | Extract per-cluster embeddings from SpeakerKit output and store with the session | 4 | EM-095 |
| EM-211 | People library | Renaming a speaker offers "Remember this voice"; People list in Settings with delete | 4 | EM-210 |
| EM-212 | Matching | Match new clusters to known people with a confidence threshold; uncertain → suggestion only | 5 | EM-211 |
| EM-213 | Consent & privacy | Voice prints stay local, explained in UI; one-click forget person | 2 | EM-211 |
| EM-214 | Tests | Threshold tuning on corpus; false-match rate target < 5% | 4 | EM-212 |
| | **Sprint total** | | **19** | |

#### Sprint 21 — Integrations I (Mar 15 – Mar 21)

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-220 | Integration framework | Per-integration settings, Keychain tokens, "on summary ready" trigger + manual "Send to…" menu, retry queue via JobRunner | 4 | v1.0 |
| EM-221 | Webhook | JSON payload (summary, action items, link to audio not included) with HMAC signature | 2 | EM-220 |
| EM-222 | Slack | Incoming webhook: formatted summary + action items | 3 | EM-220 |
| EM-223 | Notion | Create page in chosen database (summary, action items as to-dos, transcript toggle) | 5 | EM-220 |
| EM-224 | Share sheet & Apple Notes | `NSSharingService` for Mail/Messages/Notes | 2 | — |
| EM-225 | Tests | Payload golden files; mocked APIs | 3 | all above |
| | **Sprint total** | | **19** | |

#### Sprint 22 — Integrations II (Mar 22 – Mar 28)

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-230 | Confluence | Create/update a page under a chosen space/parent (storage format), API token auth | 5 | EM-220 |
| EM-231 | Jira | Create issues from selected action items (project, type, assignee mapping, due date) and link back | 6 | EM-220 |
| EM-232 | Sent-to tracking | Per-session record of where it was sent with links; avoid duplicates on re-send | 3 | EM-230 |
| EM-233 | Tests | Mocked REST tests; manual run against a test site/project | 4 | all above |
| | **Sprint total** | | **18** | |

#### Sprint 23 — Encryption at rest (Mar 29 – Apr 4)

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-240 | Key management | 256-bit key in Keychain (this device only); optional Touch ID unlock | 3 | v1.0 |
| EM-241 | Encrypted audio | AES-GCM chunked file format for chunks and final tracks; streaming decrypt for player, STT and download | 6 | EM-240 |
| EM-242 | Encrypted database | SQLCipher build of GRDB; migration of existing library with progress + backup | 6 | EM-240 |
| EM-243 | Settings & recovery | Turn on/off, export key, warning that losing the key loses the data | 2 | EM-241 |
| EM-244 | Tests | Round-trip, crash during migration, performance (recording CPU unchanged) | 4 | all above |
| | **Sprint total** | | **21** | |

#### Sprint 24 — Bengali UI → v2.0 (Apr 5 – Apr 11)

| ID | Task | Details | Est (h) | Depends |
|---|---|---|---|---|
| EM-250 | String catalogue | Move all UI strings to `Localizable.xcstrings`; pseudo-locale pass for truncation | 5 | — |
| EM-251 | Bengali translation | Translate UI, notifications, onboarding; Bengali digits/dates via locale formatters | 6 | EM-250 |
| EM-252 | Summary language | Summaries/Ask answer in Bengali when chosen (prompt + schema keys stay English) | 2 | EM-251 |
| EM-253 | Review & fixes | Native-speaker review; layout fixes for longer strings | 4 | EM-251 |
| EM-254 | Release v2.0 | Test matrix delta, tag `v2.0.0` | 3 | all above |
| | **Sprint total** | | **20** | |

### 5.3 Effort summary (Phase 2 & 3)

| Sprint | Theme | Hours |
|---|---|---|
| S13 | Live transcript | 23 |
| S14 | Browser meetings | 23 |
| S15 | More apps & cloud STT | 23 |
| S16 | Templates & Ask | 23 |
| S17 | Calendar & exports | 22 |
| S18 | Signal-level AEC | 22 |
| **Phase 2** | **6 sprints → v1.5** | **136 h** |
| S19 | Cross-meeting Q&A | 23 |
| S20 | Voice-print speakers | 19 |
| S21 | Integrations I | 19 |
| S22 | Integrations II | 18 |
| S23 | Encryption at rest | 21 |
| S24 | Bengali UI | 20 |
| **Phase 3** | **6 sprints → v2.0** | **120 h** |

Phase 3 sprints are deliberately lighter: they leave room for bugs reported from daily use of v1.5.

### 5.4 Phase 2/3 checkpoints

| When | Checkpoint | If it fails |
|---|---|---|
| End EM-140 | Live latency ≤ 5 s at acceptable CPU | Ship live transcript for the call track only, or local "tiny" model + note in UI |
| End EM-150 | Browser titles readable without Screen Recording being annoying | Rely on the "Browser is using mic — record?" prompt; titles optional |
| End S15 | A cloud engine clearly beats local on Bengali | Keep local default; cloud as opt-in per app only |
| End EM-190 | AEC reduces duplicates without damaging your voice | Keep transcript-level de-dup only; drop EM-192–194 |
| End S20 | False speaker matches < 5% | Keep voice prints as suggestions only |
| End EM-242 | DB encryption migration safe on a large library | Encrypt audio only; DB relies on FileVault |

---

## 6. Risk-driven checkpoints

| When | Checkpoint | If it fails |
|---|---|---|
| End S0 | Process tap captures all 3 apps | Switch failing app to ScreenCaptureKit fallback; add 1 sprint |
| End S1 | Local STT fast/accurate enough (esp. Bengali) | Make cloud STT the default for Bengali; pull EM-096 forward |
| End S1 | Diarization ≥ 80% | Ship MVP with "Me / Others" only; diarization to Phase 2 |
| End S6 | No false auto-starts in a week of normal use | Set noisy apps to Ask mode; tighten rules (require output activity) |
| End S10 | Summaries useful on real calls | Iterate prompts/templates before UI polish |
| End S12 | One week of daily use without lost recordings | Hold v1.0 tag; fix and repeat the week |

---

## 7. Working practices

- **Branching:** `main` always runnable; one short-lived branch per task ID (`em-042-process-tap`).
- **Commits:** reference task IDs (`EM-042: process tap teardown order`).
- **Sprint ritual (solo):** Monday — pick tasks, update this file's status; Sunday — 15-min review: demo to yourself, note learnings in `docs/sprint-log.md`, re-estimate the next sprint.
- **Using an AI coding assistant:** give it the task row + relevant Tech Design section as context; keep real-time audio code (EM-040, EM-042, EM-044, EM-050) under careful manual review — rules: no allocation, locks or `await` on audio threads.
- **Test calls:** keep a second device (phone) logged into Teams/Zoom/WhatsApp for repeatable test calls.

---

## Changelog

- **v0.1 (2026-10-14)** — Initial sprint plan: 13 one-week sprints to MVP v1.0 (~296 h), Phase 2/3 outline.
- **v0.2 (2026-10-17)** — Phase 2 & 3 expanded into sprint-level tasks: S13–S18 (EM-140…196, ~136 h → v1.5) and S19–S24 (EM-200…254, ~120 h → v2.0); carry-overs and checkpoints.
