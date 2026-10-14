# EM-077 — Real-call tuning checklist

Goal: auto-recording starts within *Start after* + 1 s of a real call, stops within *Stop after* + 2 s of
hanging up, and never records voice notes or dictation.

Every decision is appended to `~/Library/Application Support/EchoMinutes/Logs/detection.log`.
After a batch of calls run:

```bash
scripts/detection-report.py                 # whole log
scripts/detection-report.py --since 2026-10-15
```

It pairs starts/ends and flags SHORT (false start), EARLY (stopped mid-call) and RETRY (start delay too long).
Adjust in **Settings ▸ Detection** (per app), or change the defaults in `Resources/DetectionRules.json`.

## Calls to make (3 per app)

| # | Scenario | Expected log |
|---|---|---|
| 1 | Normal call, 2+ min, hang up | `CANDIDATE_MIC_ON` → `STARTED_AUTO` (+5 s) → `ENDED_GRACE` (+15 s after hang-up) |
| 2 | Call with 1–2 min muted in the middle | single recording, no end while muted |
| 3 | Leave and rejoin within 30 s | either one recording, or two — note which; tune *Stop after* if you want one |
| 4 | WhatsApp voice note (< 8 s) | `CANDIDATE_MIC_ON` → `IGNORED_DEBOUNCE`, nothing in Library |
| 5 | Siri / dictation | nothing logged (CoreSpeech ignored) |
| 6 | Teams: hang up but keep Teams open | `ENDED_GRACE` or `ENDED_MIC_OFF_LONG` (≤ 60 s) |
| 7 | Second app's call during a recording | one `NOTIFIED_OTHER_APP` + notification |
| 8 | App set to *Never* / *Ask first* | `IGNORED_RULE_NEVER` / `ASKED_USER` + notification |

## Results

| App | Calls | Flags | Changes made |
|---|---|---|---|
| Teams | | | |
| Zoom | | | |
| WhatsApp | | | |
