# EchoMinutes v1.0 — Acceptance sign-off (EM-137)

Criteria from Feature Spec §14. Fill in date, evidence (meeting title / diagnostics bundle) and result.

| # | Criterion | How to verify | Result | Evidence |
|---|---|---|---|---|
| 1 | Teams/Zoom/WhatsApp call auto-records with no prompt within debounce + 1 s; first 10 s kept; notification with Stop/Discard | Start each call; check `detection-report.py` start delay and the first words in the transcript | | |
| 2 | Opening Zoom/Teams without joining never records | Leave apps open 10 min without a call | | |
| 3 | Mic + remote voices recorded, no other apps' audio | Play music in Spotify during a call; Listen to "Only the call" | | |
| 4 | Call end stops within grace + 2 s | `detection-report.py`: ENDED_GRACE time vs hang-up | | |
| 5 | 30-min meeting → transcript with names + timestamps; click-to-seek | Open the meeting, click lines | | |
| 6 | Valid key → automatic summary (TL;DR, decisions, actions); invalid key → clear error, transcript kept | Break the key in Settings ▸ Providers, Regenerate | | |
| 7 | API keys only in Keychain — none in data folder, logs, exports | `grep -rIl "sk-ant-\|sk-proj-\|AIza" ~/Library/Application\ Support/EchoMinutes build/diag` → no matches; check a diagnostics bundle and an export | | |
| 8 | Force-quit mid-recording → relaunch recovers audio up to the last 30 s chunk | `kill -9 $(pgrep -x EchoMinutes)` mid-call, relaunch, Recover | | |
| 9 | Search a word from a past meeting → opens it at that time | Library search | | |
| 10 | WhatsApp set to Never → never recorded | Settings ▸ Detection ▸ WhatsApp ▸ Never; make a WhatsApp call | | |

Exit criteria: all 10 pass, and one full week of real meetings with no lost recording.

Signed off: ____________  Date: ________  Version: 1.0.0
