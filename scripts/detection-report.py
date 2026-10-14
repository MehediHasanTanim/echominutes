#!/usr/bin/env python3
"""EM-077: summarise EchoMinutes' detection log for real-call tuning.

Usage: scripts/detection-report.py [path/to/detection.log] [--since YYYY-MM-DD]
Default log: ~/Library/Application Support/EchoMinutes/Logs/detection.log

Pairs each start with its end and flags things worth tuning:
  * SHORT  — a recording shorter than 60 s (possible false start → raise "Start after")
  * EARLY  — ended by ENDED_GRACE but the same app restarted within 2 min (call didn't really end → raise "Stop after")
  * IGNORED_DEBOUNCE right before a start of the same app (a real call needed two tries → lower "Start after")
"""
import os, re, sys
from collections import defaultdict
from datetime import datetime, timedelta

path = os.path.expanduser("~/Library/Application Support/EchoMinutes/Logs/detection.log")
since = None
args = sys.argv[1:]
while args:
    a = args.pop(0)
    if a == "--since": since = datetime.fromisoformat(args.pop(0))
    else: path = a

if not os.path.exists(path):
    sys.exit(f"No detection log yet at {path}\n"
             "It is created when the app (this build or newer) starts with Auto-record on, and grows with each\n"
             "detection decision. Make a call (or a voice note), then run this again.")

LINE = re.compile(r"^(\S+)\s+(\S+)\s+(\S+)(?:\s+\((.*)\))?$")
events = []
for raw in open(path, encoding="utf-8"):
    if raw.startswith("#"): continue
    m = LINE.match(raw.strip())
    if not m: continue
    t = datetime.fromisoformat(m.group(1))
    if since and t.replace(tzinfo=None) < since: continue
    events.append((t, m.group(2), m.group(3), m.group(4) or ""))

if not events:
    sys.exit(f"No events in {path}")

STARTS = {"STARTED_AUTO", "STARTED_USER_ACCEPTED"}
ENDS = {"ENDED_GRACE", "ENDED_MIC_OFF_LONG", "ENDED_APP_QUIT", "ENDED_SLEEP", "ENDED_MANUAL", "DISCARDED_MANUAL"}
open_start = {}
calls = []                       # (app, start, end, end_reason)
counts = defaultdict(lambda: defaultdict(int))
last_ignored = {}
flags = []

for t, reason, app, detail in events:
    counts[app][reason] += 1
    if reason == "IGNORED_DEBOUNCE":
        last_ignored[app] = t
    elif reason in STARTS:
        if app in last_ignored and t - last_ignored[app] < timedelta(seconds=90):
            flags.append(f"{t:%m-%d %H:%M}  {app:9} RETRY   mic dropped during 'Start after', then started — consider lowering it")
        open_start[app] = t
    elif reason in ENDS and app in open_start:
        calls.append((app, open_start.pop(app), t, reason))

for i, (app, s, e, why) in enumerate(calls):
    dur = (e - s).total_seconds()
    if dur < 60 and why != "DISCARDED_MANUAL":
        flags.append(f"{s:%m-%d %H:%M}  {app:9} SHORT   recorded only {dur:.0f} s ({why}) — false start? consider raising 'Start after'")
    if why == "ENDED_GRACE":
        nxt = next((c for c in calls[i + 1:] if c[0] == app), None)
        if nxt and (nxt[1] - e) < timedelta(minutes=2):
            flags.append(f"{e:%m-%d %H:%M}  {app:9} EARLY   ended, restarted {int((nxt[1] - e).total_seconds())} s later — consider raising 'Stop after'")

print(f"Log: {path}\n{events[0][0]:%Y-%m-%d %H:%M} → {events[-1][0]:%Y-%m-%d %H:%M}, {len(events)} decisions\n")
print("Per app:")
for app, c in sorted(counts.items()):
    print(f"  {app:10} " + ", ".join(f"{k}={v}" for k, v in sorted(c.items())))
print("\nRecordings:")
for app, s, e, why in calls:
    print(f"  {s:%m-%d %H:%M:%S}  {app:9} {str(e - s).split('.')[0]:>8}  {why}")
for app, s in open_start.items():
    print(f"  {s:%m-%d %H:%M:%S}  {app:9}  (still recording / no end logged)")
print("\nFlags:" if flags else "\nFlags: none — current timings look fine.")
for f in flags: print("  " + f)
