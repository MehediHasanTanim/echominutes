# EM-140 — Live transcript: model choice & latency

**Goal:** pick the default live model (`base` or `small`) from real numbers on this Mac.
Targets: text visible ≤ 5 s after speech; recording + live < 15 % CPU, < 400 MB (EM-147).

## How to measure

1. Settings ▸ Transcription ▸ Live transcript: **on**, choose the model.
2. Make a 5-minute test call (Teams/Zoom/WhatsApp), talk normally on both sides.
3. In a terminal during the call: `scripts/perf-check.sh 60 live`
4. After the call, pass timings from the log:
   `log show --last 15m --predicate 'subsystem == "com.tanimkabir.echominutes" AND category == "stt"' | grep "Live pass"`
   (logged on the 1st pass and every 50th, with the running average).
5. Watch the mini widget: roughly how long until grey text appears, and until it turns black (committed)?

## Results

| Model | Language | Avg pass (s) | Grey text after (s) | Committed after (s) | CPU avg % | RSS peak MB | Quality notes |
|---|---|---|---|---|---|---|---|
| base | en | | | | | | |
| base | bn | | | | | | |
| small | en | | | | | | |
| small | bn | | | | | | |

**Decision:** default live model = ___ (change `LivePreferences.defaultModel` if not `base`).

## Design notes (as built)

- A pass runs per track when ≥ 1.5 s of new audio is waiting; it transcribes from the last commit point (≤ 15 s, hard cap 26 s).
- Commit rule (`LiveWindow`): same text at the same place in two consecutive passes **and** ending ≥ 1.5 s before the newest audio. Expected commit delay ≈ 2.5–4.5 s; grey text ≈ 1.5–3 s.
- Silence (energy VAD) never reaches the model. The hallucination guard runs on every pass.
- Pauses on Low Power Mode, battery < 20 % or thermal state ≥ serious; audio during a pause is skipped (the recording itself is unaffected).
- If the transcriber falls behind, the live feed drops audio (`LiveAudioTap`), never the recording.
