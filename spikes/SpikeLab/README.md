# SpikeLab (EM-003)

Throwaway experiment app for the Sprint 0–1 spikes. **Not production code** — nothing here is imported by EchoMinutes.

- Swift package (`Package.swift`), wrapped into a signed `SpikeLab.app` by `build.sh`.
- Hardened Runtime, `com.apple.security.device.audio-input`, no App Sandbox.
- Info.plist: `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, `LSUIElement` (no Dock icon).
- Bundle ID `com.tanimkabir.echominutes.spikelab`, signed with the Apple Development identity from `Config/Signing.local.xcconfig`.
- Always launch through `run.sh` (uses `open`), so macOS privacy permissions are granted to **SpikeLab**, not Terminal.

## Usage

```bash
spikes/SpikeLab/run.sh            # = all: info + mic + tap-probe
spikes/SpikeLab/run.sh help
spikes/SpikeLab/run.sh mic
BUILD=0 spikes/SpikeLab/run.sh info   # skip rebuild
```

Logs are saved to `spikes/SpikeLab/output/` (git-ignored).
Edit in Xcode with `open spikes/SpikeLab/Package.swift` (build/run via the scripts, not Xcode's Run button).

## Commands

| Command | Task | Purpose |
|---|---|---|
| `info` | EM-003 | Bundle ID, signing team, Hardened Runtime, entitlements, usage strings |
| `mic` | EM-003 | Microphone permission status / request |
| `tap-probe` | EM-003 | Create + destroy a Core Audio process tap |
| `processes` | EM-004 | Live table of audio processes (PID, mic, output, owning app, executable, audio bundle ID) + change events; CSV to `output/processes-*.csv`. Options `--all`, `--filter <text>`, `--duration <sec>`; Ctrl+C stops cleanly |
| `capture` | EM-005 | Record one app's audio output (process tap + private aggregate device) to `output/capture-*.wav` with a 1 s level meter. `--app <text>` or `--global`, `--duration <sec>` |

## Reset permissions

```bash
tccutil reset Microphone com.tanimkabir.echominutes.spikelab
tccutil reset AudioCapture com.tanimkabir.echominutes.spikelab   # System Audio Recording
```

## Verification (2026-10-14)

`run.sh all` on macOS 26.6.2 / Xcode 27.0 → **ALL CHECKS PASSED**: bundle ID `com.tanimkabir.echominutes.spikelab`, team G26QS5R4FS, Hardened Runtime on, `audio-input` entitlement present, both usage strings present, microphone granted, process tap created (48 kHz, 2 ch, 32-bit float) and destroyed.
