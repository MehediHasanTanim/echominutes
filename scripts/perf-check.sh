#!/bin/bash
# EM-135: samples EchoMinutes' CPU and memory and compares with the targets
# (idle CPU < 1 %, recording CPU < 5 %, memory < 200 MB; transcription/summary jobs excluded).
# EM-147: label "live" = recording with the live transcript on (CPU < 15 %, memory < 400 MB).
# Usage: scripts/perf-check.sh [seconds=60] [label]
#   Run once while idle (menu bar, no call) and once during a call:  scripts/perf-check.sh 60 recording
#   With Settings ▸ Transcription ▸ Live transcript on, during a call:  scripts/perf-check.sh 60 live
set -u
SECS="${1:-60}"; LABEL="${2:-idle}"
PID=$(pgrep -x EchoMinutes) || { echo "EchoMinutes is not running"; exit 1; }
echo "▶ Sampling EchoMinutes (pid $PID) for ${SECS}s — label: $LABEL"
CPU=(); MEM=()
for ((i = 0; i < SECS; i++)); do
  read -r c m <<<"$(ps -o %cpu=,rss= -p "$PID")" || break
  CPU+=("$c"); MEM+=("$m"); sleep 1
done
python3 - "$LABEL" "${CPU[*]}" "${MEM[*]}" <<'PY'
import sys, statistics as st
label, cpu, mem = sys.argv[1], [float(x) for x in sys.argv[2].split()], [int(x) / 1024 for x in sys.argv[3].split()]
limit = {"idle": 1.0, "live": 15.0}.get(label, 5.0)
mem_limit = 400 if label == "live" else 200
avg, p95 = st.mean(cpu), sorted(cpu)[int(len(cpu) * 0.95) - 1]
peak = max(mem)
print(f"  CPU  avg {avg:.1f}%  p95 {p95:.1f}%  (target < {limit:.0f}%)  {'✔' if avg < limit else '✘'}")
print(f"  RSS  avg {st.mean(mem):.0f} MB  peak {peak:.0f} MB  (target < {mem_limit} MB)  {'✔' if peak < mem_limit else '✘'}")
print("  Note: RSS includes the speech model while a transcription runs (≈1.5 GB for turbo) — measure outside jobs.")
PY
