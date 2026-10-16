# EM-097 — Transcript quality check

Run after Sprint 8 on real recordings (Library ▸ meeting ▸ **Re-transcribe** applies the current pipeline).

| # | Recording | Check | Result |
|---|---|---|---|
| 1 | 1:1 Teams call, **headphones** | "You" lines only from your mic; other side one speaker (no Speaker 1/2 split) | |
| 2 | 1:1 call on **Mac speakers** | Echo note shown; no duplicated lines (target < 5 % of lines) | |
| 3 | 3-person Zoom call | Speaker 1 / 2 match the real people ≥ 80 % of lines; rename both, Re-transcribe keeps names | |
| 4 | Bengali (or mixed) WhatsApp call, language = Bengali | Bengali script, readable; note words wrong per minute | |
| 5 | Long call (30 min+) | Transcribes without error; note time taken (Logs: "RTF") | |
| 6 | Search | Search a word you said → hit opens the meeting and plays from that line | |

Notes per recording: wrong words / minute (rough WER), missing speech, hallucinated lines, speaker mix-ups.
If Bengali is unusable locally, enable EM-096 (cloud STT) — otherwise it stays deferred to Phase 2.
