# EM-160 / EM-161 / EM-168 — More apps & cloud transcription: verification

## 1. Slack, FaceTime, Webex detection (EM-160 / EM-161)

Rules added from documentation and app layouts; confirm on your Mac with **Detection Monitor** (Settings ▸ Diagnostics)
and the decision log:
`log show --last 30m --predicate 'subsystem == "com.tanimkabir.echominutes" AND category == "detection"' | grep -E "CANDIDATE|STARTED|ENDED|IGNORED"`

Use the EM-077 checklist (`docs/testing/EM-077-real-call-tuning.md`): 3 calls per app incl. mute / rejoin.

| App | Bundle prefixes in rules | Check | Result |
|---|---|---|---|
| Slack huddle | `com.tinyspeck.slackmacgap` (helpers) | huddle auto-records ~5 s after joining; message / notification sounds never start anything; leaving ends it within ~15 s | |
| Slack call (1:1) | same | as above | |
| FaceTime audio / video | `com.apple.FaceTime`, `com.apple.avconferenced` | records after answering; ringing alone doesn't; hang-up ends it | |
| iPhone call relayed to the Mac | `com.apple.avconferenced` | recorded as "FaceTime" (rename if you don't want these: set FaceTime to Ask first) | |
| Webex meeting | `Cisco-Systems.Spark`, `com.cisco.webexmeetingsapp`, `com.webex.meetingmanager` | auto-records; lobby / audio test before joining doesn't | |

If an app isn't detected: in Detection Monitor note which bundle ID holds the mic during the call and add it to
`bundlePrefixes` in `Resources/DetectionRules.json`. Tune `debounceSec` / `graceSec` per app.

## 2. Cloud engines vs local (EM-168)

Same recording, transcribed with each engine (Settings ▸ Transcription ▸ "Transcribe with", then **Re-transcribe**).
Use the EM-097 corpus where possible (English, Bengali, 3-person, speakers).

| Recording | Engine | Time to transcript | Quality notes (names, Bengali, speakers, echo) |
|---|---|---|---|
| | Local (Whisper turbo) | | |
| | Deepgram Nova-3 | | |
| | AssemblyAI Universal | | |
| | OpenAI whisper-1 | | |
| | OpenAI gpt-4o-transcribe | | |

Cost: see each provider's current pricing; Settings ▸ Transcription shows minutes sent this month per engine.

**Decision:** default engine stays **Local**; cloud for: ___ (per app).
