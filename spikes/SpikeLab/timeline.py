#!/usr/bin/env python3
"""EM-007 — merge a `processes` events CSV with scenario step markers into a timeline report.

Usage: timeline.py <processes-*.csv> <scenario-*.markers.csv> [--out report.md]
Prints a Markdown report: event timeline relative to each step, mic/output state per step,
and the latencies that drive detection tuning (join→mic on, leave→mic off, idle false-positives).
"""
import csv, sys, os
from collections import defaultdict

def load(events_path, markers_path):
    events = []
    with open(events_path) as f:
        for r in csv.DictReader(f):
            events.append({"ms": int(r["epoch_ms"]), "event": r["event"], "pid": r["pid"],
                           "bundle": r["audio_bundle_id"], "exe": r["executable"],
                           "input": r["input"] == "1", "output": r["output"] == "1"})
    markers = []
    with open(markers_path) as f:
        for r in csv.DictReader(f):
            markers.append((int(r["epoch_ms"]), r["step"]))
    return sorted(events, key=lambda e: e["ms"]), sorted(markers)

def step_at(markers, ms):
    cur = "before_start"
    for m, name in markers:
        if m <= ms: cur = name
    return cur

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None
    if len(args) < 2: print(__doc__); sys.exit(2)
    events, markers = load(args[0], args[1])
    t0 = markers[0][0]
    rel = lambda ms: f"{(ms - t0) / 1000:7.2f}s"
    L = []
    L.append(f"# Detection timeline — {os.path.basename(args[1])}\n")
    L.append("## Steps\n\n| t | step |\n|---|---|")
    for m, n in markers: L.append(f"| {rel(m)} | {n} |")

    L.append("\n## Events (input/output changes & process add/remove)\n\n| t | step | event | pid | process | mic | out |\n|---|---|---|---|---|---|---|")
    for e in events:
        if e["event"].endswith("_initial"): continue
        L.append(f"| {rel(e['ms'])} | {step_at(markers, e['ms'])} | {e['event']} | {e['pid']} | {e['exe']} ({e['bundle']}) | {'●' if e['input'] else '·'} | {'●' if e['output'] else '·'} |")

    # Reconstruct app-level mic/output state over time (any matching process)
    state = defaultdict(lambda: {"input": False, "output": False})
    timeline = []  # (ms, app_mic, app_out)
    for e in events:
        if e["event"] == "process_removed":
            state.pop(e["pid"], None)
        else:
            state[e["pid"]] = {"input": e["input"], "output": e["output"]}
        timeline.append((e["ms"], any(s["input"] for s in state.values()), any(s["output"] for s in state.values())))

    def app_state(ms):
        mic = out = False
        for t, m, o in timeline:
            if t <= ms: mic, out = m, o
        return mic, out

    def first_change(after_ms, field, value, before_ms=None):
        m0, o0 = app_state(after_ms)          # already in the wanted state at the start?
        if (m0 if field == "mic" else o0) == value: return after_ms
        for t, m, o in timeline:
            if t < after_ms: continue
            if before_ms and t > before_ms: break
            if (m if field == "mic" else o) == value: return t
        return None

    L.append("\n## App-level state per step (any process of the app)\n\n| step | mic ON at any time | output ON at any time | mic ON % of step |\n|---|---|---|---|")
    bounds = markers + [(events[-1]["ms"] if events else markers[-1][0], "_end")]
    for (start, name), (end, _) in zip(bounds, bounds[1:]):
        if end <= start: continue
        mic_on_ms = 0; any_mic = any_out = False
        pts = [start] + [t for t, _, _ in timeline if start < t < end] + [end]
        for a, b in zip(pts, pts[1:]):
            m, o = app_state(a)
            any_mic |= m; any_out |= o
            if m: mic_on_ms += b - a
        L.append(f"| {name} | {'YES' if any_mic else 'no'} | {'YES' if any_out else 'no'} | {100 * mic_on_ms / (end - start):.0f}% |")

    mk = dict((n, m) for m, n in markers)
    L.append("\n## Key measurements\n")
    def lat(label, start_step, field, value, end_step=None):
        if start_step not in mk: return
        t = first_change(mk[start_step] - 3000, field, value, mk.get(end_step))
        L.append(f"- **{label}:** " + (f"{(t - mk[start_step]) / 1000:+.2f} s relative to '{start_step}'" if t else "not observed"))
    lat("Mic ON after join/answer", "joined" if "joined" in mk else "call_answered", "mic", True)
    lat("Mic ON during ringing/pre-join", "prejoin_screen" if "prejoin_screen" in mk else "call_started", "mic", True,
        "joined" if "joined" in mk else "call_answered")
    lat("Mic OFF after leaving", "left_call", "mic", False)
    lat("Output OFF after leaving", "left_call", "output", False)
    if "muted" in mk and "unmuted" in mk:
        m_mid, _ = app_state((mk["muted"] + mk["unmuted"]) // 2)
        L.append(f"- **Mic while muted:** {'stays ON (mute does not release mic)' if m_mid else 'turns OFF (mute releases mic!)'}")
    if "app_launched" in mk:
        nxt = mk.get("prejoin_screen") or mk.get("call_started")
        on = first_change(mk["app_launched"], "mic", True, nxt)
        L.append(f"- **Mic used while app idle (no call):** {'YES ⚠ false-start risk' if on else 'no'}")
    if "app_idle_after" in mk:
        on = first_change(mk["app_idle_after"], "mic", True, mk.get("app_quit"))
        L.append(f"- **Mic used while idle after call:** {'YES ⚠' if on else 'no'}")

    text = "\n".join(L) + "\n"
    if out:
        open(out, "w").write(text); print(f"Wrote {out}")
    else:
        print(text)

if __name__ == "__main__":
    main()
