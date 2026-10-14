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

## Run 2 — Teams clip, turbo, forced language, no VAD (2026-10-14)

| Setting | Result |
|---|---|
| `--lang bn --no-vad` | **0 segments** — forcing the wrong language makes Whisper reject everything |
| `--lang en --no-vad` | 6 segments covering 0–14 s and 26–31 s (VAD run had missed 0–14 s); music section 14–26 s correctly left empty; RTF **0.136** (7× real time) |

Segment diagnostics (en): five "Hello!" segments decoded only at **temperature 1.0** (all fallbacks used) with **compression ratio 3.0** and avgLogprob −0.95 → low-confidence guesses; the final "I know that." decoded at temp 0.0, compression 1.07, avgLogprob −0.55 → confident.

### Conclusions
- **WhisperKit's VAD chunking drops real speech** on call audio → use no-chunking (≤30 s windows sliding) or our own VAD with a conservative threshold + padding.
- **Wrong forced language ⇒ empty output**; auto-detect ⇒ wrong language. → language must be a user setting (per app / per meeting) with an easy "re-transcribe as…" action; consider trying the 2 configured languages and keeping the higher avgLogprob.
- **Confidence gate for the hallucination guard:** drop or flag segments with `temperature ≥ 1.0` **and** `compressionRatio > 2.4`, or `avgLogprob < −1.0`, or `noSpeechProb > 0.6`.
