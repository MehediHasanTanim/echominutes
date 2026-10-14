# EchoMinutes

Personal macOS menu bar utility that auto-detects calls (Teams, Zoom, WhatsApp, …), records both sides, transcribes them and produces AI meeting summaries with your own LLM API key.

## Docs
- [Feature spec](docs/feature/FEATURE_SPEC.md)
- [Technical design](docs/design/TECHNICAL_DESIGN.md)
- [Implementation plan](docs/plan/IMPLEMENTATION_PLAN.md)
- [Signing setup (EM-002)](docs/setup/SIGNING.md)

## Requirements
- macOS 14.4+ (Apple Silicon recommended), latest Xcode
- Apple Development signing identity — run `scripts/check-signing.sh --write-local`

## Build & run the app

```bash
scripts/bootstrap.sh     # once: installs XcodeGen (Homebrew) and generates EchoMinutes.xcodeproj from project.yml
scripts/run.sh           # build (Debug), verify signing/entitlements, launch → waveform icon in the menu bar
scripts/build.sh Release # release build + checks
xed .                    # open in Xcode
```

The Xcode project is generated from `project.yml` — edit that file, not the `.xcodeproj` (git-ignored).

## Branching
- `main` is always runnable.
- One short-lived branch per task: `em-<id>-<slug>` (e.g. `em-042-process-tap`); commit messages start with the task ID (`EM-042: …`).
