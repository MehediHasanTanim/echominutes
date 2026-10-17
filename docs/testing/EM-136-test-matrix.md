# EM-136 — Manual test matrix (v1.0)

Before each block: `scripts/build.sh && scripts/run.sh` (or the installed Release build). After any failure:
Settings ▸ Diagnostics ▸ **Export diagnostics bundle…** and note the file name here.

Legend: ✔ pass · ✘ fail (link note) · – not applicable

| Scenario | Teams | Zoom | WhatsApp |
|---|---|---|---|
| Headphones (wired / USB): auto start, auto stop, transcript both sides | | | |
| Mac speakers: echo removed (no duplicated lines), "speakers" note shown | | | |
| AirPods, switch to speakers mid-call (rate change 48k↔16k) — recording continues, no gap > 2 s | | | |
| Mute yourself 5 min mid-call — one recording, not split | | | |
| App crash: `kill -9` EchoMinutes mid-call → relaunch → Recover (audio up to last 30 s chunk) | | | |
| Mac sleep mid-call (close lid) → recording finalised, nothing lost before sleep | | | |
| No network after the call → transcript OK, summary retried later automatically | | | |
| Invalid API key → clear "key rejected" message + Open Settings; transcript intact | | | |
| App set to **Never** → no recording, `IGNORED_RULE_NEVER` in detection log | | | |
| App open without a call (pre-join screen, chat) for 5 min → no recording | | | |
| Spotify/YouTube playing during the call → not in the recording | | | |
| 30+ min call → transcript + summary complete, no crash (Diagnostics log clean) | | | |

Performance (EM-135): `scripts/perf-check.sh 60 idle` → ___ % / ___ MB · during a call `scripts/perf-check.sh 60 recording` → ___ % / ___ MB
