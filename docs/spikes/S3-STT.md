# Spike S3 — Local transcription (WhisperKit) findings

Machine: Apple Silicon (M4 Pro), macOS 26.6.2. Data: `spikes/SpikeLab/output/stt-bench.csv`, `transcript-*.txt`.

## Run 1 — 2026-10-14, 6 short captures (≤ 31 s), auto language, VAD chunking

| Model | Model load (first run) | Peak RSS | Warm RTF (WhatsApp 31 s) | Notes |
|---|---|---|---|---|
| base | 41 s | 317 MB | 0.03 | misses most speech |
| small | 88 s | 397 MB | 0.15 | best English-looking output, but **translated/hallucinated** Bengali speech into English |
| large-v3 turbo | 264 s (download + Core ML specialization) | 1.5 GB | 0.36 | first file took 118 s (warm-up); correct words for Bengali but in the **wrong script** |

### Findings
1. **Language auto-detect is unreliable on call audio.** Detected `ko`, `de`, `is` on English/Bengali clips. The WhatsApp call (Bengali) was transcribed by turbo as Bengali words written in **Gujarati script**; `small` turned it into English.
   → **Do not auto-detect per file.** Use a per-app / per-session language setting (default `bn` or `en` chosen by the user), forced with `usePrefillPrompt`.
2. **Large parts of speech were dropped.** WhatsApp 0–16 s and Teams 0–12 s contain speech (spectral check) but produced no text with VAD chunking. → re-test with `--no-vad` and forced language; if VAD is the cause, use our own energy VAD with a lower threshold (Tech Design §9.3) instead of WhisperKit's.
3. **Classic Whisper hallucinations on silence/music:** "Продолжение следует…" over 30 s of Zoom digital silence, `[Music]`, `*Music playing*`. → hallucination guard (EM-086) confirmed necessary: drop segments over silent audio, no-speech-prob filter, known-phrase blacklist.
4. **First-run cost:** turbo needs ~4–6 min one-time (download + Core ML specialization) and the first transcription is slow (warm-up). Onboarding must download + warm up the model before the first meeting.
5. **Speed is fine:** warm turbo ≈ 0.36 RTF on short clips (short clips overstate overhead; re-measure on 10-min audio).

## Next (EM-012 continued / EM-013)
- Re-run WhatsApp + Teams clips with `--lang bn --no-vad` (turbo) to separate VAD vs language issues.
- Record 5–10 min real calls (EN, BN, mixed) for realistic RTF and quality.
- Cloud baseline for Bengali (EM-013).
