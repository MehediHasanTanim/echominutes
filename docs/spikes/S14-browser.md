# EM-150 / EM-157 — Browser meetings: verification

The code assumes (from the Sprint 0 spikes + documentation) how each browser exposes audio and titles.
This sheet confirms it on your Mac and doubles as the EM-157 manual test matrix.

## Setup

1. Settings ▸ Detection ▸ Browser meetings: **on**. Click **Allow…** (Screen & System Audio Recording), then quit and reopen EchoMinutes.
2. Open **Detection Monitor** (Settings ▸ Diagnostics) — browser meetings show up as `meet`, `teams-web`, `zoom-web` or `browser`.
3. Log of decisions: `log show --last 30m --predicate 'subsystem == "com.tanimkabir.echominutes" AND category == "detection"' | grep -E "Browser mic|CANDIDATE|STARTED|ENDED|ASKED"`

## Matrix (✔ / ✘ + note)

| # | Scenario | Chrome | Safari | Edge / Arc / Brave | Firefox |
|---|---|---|---|---|---|
| 1 | Google Meet, meeting tab visible → auto-records after ~5 s, title from tab | | | | |
| 2 | Teams web meeting → auto-records, title = meeting name | | | | |
| 3 | Zoom web client → auto-records | | | | |
| 4 | Switch to another tab mid-meeting → recording continues | | | | |
| 5 | Leave the meeting → recording stops within ~20 s (or ~60 s if the tab keeps playing sound) | | | | |
| 6 | Meeting in a background tab (other tab visible) → "Browser is using the microphone — record?" | | | | |
| 7 | Without Screen Recording permission → the question appears instead of auto-record | | | | |
| 8 | Voice search / dictation on a normal site → only the question (Not now / Never) — no recording | | | | |
| 9 | YouTube playing, no mic → nothing happens | | | | |
| 10 | "Never for browser calls" → no more questions (Detection settings show *Browser call: Never*) | | | | |
| 11 | Recording contains both sides; other browsers' sound not in it | | | | |

## Things to note if something fails

- Which process holds the mic (Detection Monitor / `Browser mic:` log line) — e.g. Firefox may use a separate audio process, Safari uses `com.apple.WebKit.GPU`.
- The exact window title (add a pattern to `Resources/DetectionRules.json` → `webMeetings`).
- Safari: audio runs in the shared WebKit GPU process, so another WebKit app playing sound at the same time can end up in the recording.

## Results / decisions

-
