#!/usr/bin/env python3
"""EM-007 (automated) — analyse background-logger CSVs: find every mic session per app and derive
detection tuning numbers (debounce / grace) from real usage. No step markers needed.

Usage: calls.py [csv ...] [--out report.md]   (default: all spikes/SpikeLab/output/processes-*.csv)
"""
import csv, glob, os, sys, datetime as dt
from collections import defaultdict

APPS = [  # (app id, bundle prefixes)
    ("teams", ["com.microsoft.teams2"]), ("zoom", ["us.zoom"]), ("whatsapp", ["net.whatsapp"]),
    ("slack", ["com.tinyspeck.slackmacgap"]), ("facetime", ["com.apple.FaceTime"]),
    ("webex", ["Cisco-Systems.Spark"]), ("discord", ["com.hnc.Discord"]),
    ("chrome", ["com.google.Chrome"]), ("safari", ["com.apple.Safari", "com.apple.WebKit"]),
    ("siri(ignore)", ["com.apple.CoreSpeech"]),
]
MEETING_APPS = {"teams", "zoom", "whatsapp", "slack", "facetime", "webex", "discord"}

def app_of(row):
    for key in (row["audio_bundle_id"], row["app_bundle_id"]):
        for app, prefixes in APPS:
            if any(key.startswith(p) for p in prefixes): return app
    return row["app_name"] or row["executable"] or "?"

def fmt_t(ms): return dt.datetime.fromtimestamp(ms / 1000).strftime("%m-%d %H:%M:%S")
def fmt_d(ms): s = ms / 1000; return f"{s:.1f}s" if s < 120 else f"{s/60:.1f}m"

def intervals_for(rows, field):
    """Union of per-PID on-intervals for one app within one CSV file."""
    state, start = {}, None
    out = []
    last_ms = rows[-1]["ms"] if rows else 0
    for r in rows:
        pid = r["pid"]
        if r["event"] == "process_removed": state.pop(pid, None)
        else: state[pid] = r[field]
        on = any(state.values())
        if on and start is None: start = r["ms"]
        if not on and start is not None: out.append((start, r["ms"])); start = None
    if start is not None: out.append((start, last_ms))
    return out

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--") and not (sys.argv.index(a) > 0 and sys.argv[sys.argv.index(a)-1] == "--out")]
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None
    here = os.path.dirname(os.path.abspath(__file__))
    files = args or sorted(glob.glob(os.path.join(here, "..", "output", "processes-*.csv")))
    mic = defaultdict(list); outp = defaultdict(list)
    for f in files:
        rows = []
        with open(f) as fh:
            for r in csv.DictReader(fh):
                r["ms"] = int(r["epoch_ms"]); r["input"] = r["input"] == "1"; r["output"] = r["output"] == "1"
                r["app"] = app_of(r); rows.append(r)
        by_app = defaultdict(list)
        for r in rows: by_app[r["app"]].append(r)
        for app, rs in by_app.items():
            mic[app] += intervals_for(rs, "input"); outp[app] += intervals_for(rs, "output")

    L = [f"# Mic session report — {len(files)} log file(s)\n",
         "Each row = a continuous period where any process of the app had the microphone open.\n"]
    rec = []
    for app in sorted(mic, key=lambda a: (a not in MEETING_APPS, a)):
        segs = sorted(mic[app])
        if not segs: continue
        L.append(f"\n## {app}{'' if app in MEETING_APPS else '  (not a meeting app)'}\n")
        L.append("| start | duration | gap before | output active around start | kind |\n|---|---|---|---|---|")
        prev_end = None; short = []; gaps_in_call = []
        for a, b in segs:
            d = b - a; gap = (a - prev_end) if prev_end else None
            out_near = any(oa <= a + 5000 and ob >= a - 5000 for oa, ob in outp[app])
            kind = "short (<10 s) — false-start candidate" if d < 10_000 else "call-like"
            if d < 10_000: short.append(d)
            if gap is not None and gap < 120_000: gaps_in_call.append(gap)
            L.append(f"| {fmt_t(a)} | {fmt_d(d)} | {fmt_d(gap) if gap is not None else '—'} | {'yes' if out_near else 'no'} | {kind} |")
            prev_end = b
        if app in MEETING_APPS:
            calls = [b - a for a, b in segs if b - a >= 10_000]
            L.append(f"\n- sessions: {len(segs)} ({len(calls)} call-like, {len(short)} short)")
            if short: L.append(f"- longest short mic use: {fmt_d(max(short))} → debounce must exceed this")
            if gaps_in_call: L.append(f"- mic gaps < 2 min between sessions: {', '.join(fmt_d(g) for g in sorted(gaps_in_call))} → grace must cover gaps that are inside one call")
            deb = max([5_000] + [s + 2_000 for s in short]) / 1000
            rec.append((app, deb))

    if rec:
        L.append("\n## Suggested starting values\n\n| app | debounce (s) |\n|---|---|")
        for app, deb in rec: L.append(f"| {app} | {deb:.0f} |")
        L.append("\nConfirm which call-like rows were real meetings; any call-like row that was NOT a meeting is a false-positive case to handle.")
    text = "\n".join(L) + "\n"
    if out: open(out, "w").write(text); print(f"Wrote {out}")
    else: print(text)

if __name__ == "__main__":
    main()
