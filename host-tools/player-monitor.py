#!/usr/bin/env python3
"""Live terminal dashboard for a player-stats feed piped in over SSH.

    ssh pi@pi-player.local player-stats 30 | host-tools/player-monitor.py
    ssh pi@pi-player.local player-stats 30 | host-tools/player-monitor.py --log soak.log

Runs on your workstation, never on the appliance: with an overlay rootfs every
write on the Pi is RAM. Nothing is written there, and --log keeps the raw feed
on your machine so a run can be re-read after the fact.

Reads the player-stats line format:

    2026-09-09 21:14:03 rss=118M swap=0M cpu=94% cma_free=181M mem_avail=402M \
cache=31M temp=57.5C hwdec=v4l2m2m-copy pos=2 throttled=0x0 file=003_clip.mp4

Fields are read by name, not position, so a sampler that grows a new key shows
it without changes here, and one that drops a key simply stops displaying it.
Stdlib only - nothing to install.
"""

import argparse
import re
import shutil
import sys
from collections import deque
from datetime import datetime

SPARK = "▁▂▃▄▅▆▇█"

# Numeric metrics, in display order: key -> (label, unit, decimals).
# Anything else numeric in the feed is appended after these under its own name.
KNOWN = {
    "rss":       ("rss",       "M", 0),
    "swap":      ("swap",      "M", 0),
    "cpu":       ("cpu",       "%", 0),
    "cma_free":  ("cma free",  "M", 0),
    "mem_avail": ("mem avail", "M", 0),
    "cache":     ("cache",     "M", 0),
    "temp":      ("temp",      "C", 1),
    "pos":       ("pos",       "",  0),
}
# Shown as text, not plotted.
TEXT_KEYS = ("hwdec", "throttled", "file")
# Metrics where the interesting question is "how far has it moved", not "what
# is it right now".
DRIFT_KEYS = ("rss", "swap", "mem_avail", "cma_free")

# Thresholds worth shouting about. CmaFree is the number that predicts a decoder
# stall, and it bottoms out while MemAvailable still looks healthy; the SoC
# starts soft-throttling at 80 C.
CMA_WARN = 64.0
TEMP_WARN = 80.0

TIMESTAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (.*)$")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


class Colour:
    def __init__(self, enabled):
        self.on = enabled

    def __call__(self, text, code):
        return f"\x1b[{code}m{text}\x1b[0m" if self.on else text

    def dim(self, t):
        return self(t, "2")

    def bold(self, t):
        return self(t, "1")

    def red(self, t):
        return self(t, "31")

    def yellow(self, t):
        return self(t, "33")

    def green(self, t):
        return self(t, "32")


def parse(line):
    """One feed line -> (timestamp, {key: value}) or None if it isn't a sample.

    Returns an empty field dict for 'mpv not running', which is a real event
    worth counting rather than a parse failure.
    """
    match = TIMESTAMP.match(line)
    if not match:
        return None
    try:
        ts = datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None

    fields = {}
    for token in match.group(2).split():
        key, sep, value = token.partition("=")
        if sep:
            fields[key] = value
    return ts, fields


def number(value):
    """Strip the trailing unit and return a float, or None if it isn't numeric.

    player-stats prints "-" for a key the kernel does not expose, which is a
    different and much less alarming answer than 0.
    """
    try:
        return float(value.rstrip("MC%"))
    except ValueError:
        return None


def spark(values, width):
    values = list(values)[-width:]
    if not values:
        return ""
    lo, hi = min(values), max(values)
    if hi - lo < 1e-9:
        return SPARK[0] * len(values)
    step = (hi - lo) / (len(SPARK) - 1)
    return "".join(SPARK[int((v - lo) / step)] for v in values)


def human(seconds):
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}h{m:02d}m" if h else f"{m}m{s:02d}s"


class Monitor:
    def __init__(self, colour):
        self.hist = {}
        self.first = {}
        self.peak = {}
        self.trough = {}
        self.text = {}
        self.samples = 0
        self.gaps = 0
        self.first_ts = None
        self.last_ts = None
        self.c = colour
        self.depth = 400   # enough history for a full-width sparkline

    def add(self, ts, fields):
        self.samples += 1
        if self.first_ts is None:
            self.first_ts = ts
        self.last_ts = ts

        if not fields:
            self.gaps += 1
            return

        for key, raw in fields.items():
            value = None if key in TEXT_KEYS else number(raw)
            if value is None:
                self.text[key] = raw
                continue
            self.hist.setdefault(key, deque(maxlen=self.depth)).append(value)
            self.first.setdefault(key, value)
            self.peak[key] = max(self.peak.get(key, value), value)
            self.trough[key] = min(self.trough.get(key, value), value)

    def order(self):
        keys = ([k for k in KNOWN if k in self.hist]
                + sorted(k for k in self.hist if k not in KNOWN))
        # A metric flat at zero all run is noise, not information - swap on a
        # healthy board is the whole reason for this. It reappears by itself
        # the moment it goes non-zero.
        return [k for k in keys if self.peak[k] or self.trough[k]]

    def rate_per_hour(self, key):
        """Change per hour over the run - the number that separates a leak from
        warm-up. None until the run is long enough for it to mean anything."""
        # Playlist position wraps to 0 at the end of the loop, so a rate is
        # nonsense for it.
        if key == "pos" or key not in self.hist or self.first_ts is None:
            return None
        span = (self.last_ts - self.first_ts).total_seconds()
        if span < 120:
            return None
        return (self.hist[key][-1] - self.first[key]) / span * 3600

    def alerts(self):
        out = []
        if "cma_free" in self.hist and self.hist["cma_free"][-1] < CMA_WARN:
            out.append(f"cma_free {self.hist['cma_free'][-1]:.0f}M - decoder stall "
                       "territory; a frozen picture with the service still "
                       "'active' looks like this")
        if "temp" in self.hist and self.hist["temp"][-1] >= TEMP_WARN:
            out.append(f"temp {self.hist['temp'][-1]:.1f}C - SoC is soft-throttling")
        if self.text.get("hwdec") in ("no", "none"):
            out.append("hwdec=no - software decode; expect ~300% cpu, RSS climbing "
                       "and an OOM kill within the hour")
        throttled = self.text.get("throttled")
        if throttled and throttled not in ("0x0", "0", "-"):
            out.append(f"throttled={throttled} - it has throttled at some point "
                       "(the flag latches, so this may be hours old)")
        if self.gaps:
            out.append(f"{self.gaps} sample(s) with mpv not running - it restarted")
        return out

    def render(self):
        c = self.c
        cols = shutil.get_terminal_size((100, 30)).columns
        lines = [c.bold(f"pi-player   {self.last_ts:%H:%M:%S}   "
                        f"samples {self.samples}   "
                        f"run {human((self.last_ts - self.first_ts).total_seconds())}"),
                 ""]

        keys = self.order()
        if not keys:
            lines.append(c.dim("  waiting for a sample with fields..."))
            return lines

        label_w = max(len(KNOWN.get(k, (k,))[0]) for k in keys)
        # Everything but the sparkline is fixed width; the spark takes the rest.
        spark_w = max(8, min(60, cols - label_w - 48))

        for key in keys:
            label, unit, decimals = KNOWN.get(key, (key, "", 0))
            values = self.hist[key]
            now = values[-1]

            note = ""
            if key in DRIFT_KEYS:
                note = (f"start {self.first[key]:.0f}  peak {self.peak[key]:.0f}  "
                        f"Δ {now - self.first[key]:+.0f}")
                rate = self.rate_per_hour(key)
                if rate is not None:
                    note += f"  ({rate:+.0f}/h)"
            elif key == "temp":
                note = f"min {self.trough[key]:.1f}  max {self.peak[key]:.1f}"
            elif key != "pos":
                note = f"min {self.trough[key]:.0f}  max {self.peak[key]:.0f}"

            paint = str
            if key == "cma_free":
                paint = c.red if now < CMA_WARN else c.green
            elif key == "temp" and now >= TEMP_WARN:
                paint = c.red

            # Pad before colouring: ANSI codes are invisible but count as width.
            value_text = f"{now:.{decimals}f}{unit}".rjust(9)
            lines.append(f"  {label:<{label_w}}  {paint(value_text)}  "
                         f"{spark(values, spark_w):<{spark_w}}  {c.dim(note)}")

        lines.append("")
        for key in TEXT_KEYS:
            if key in self.text:
                value = self.text[key]
                if key == "file":
                    value = value[: max(20, cols - 14)]
                lines.append(f"  {c.dim(key + ':'):<14} {value}")

        for text in self.alerts():
            lines.append("  " + c.yellow("! " + text))
        return lines

    def summary(self):
        if not self.samples:
            return ["no samples"]
        span = (self.last_ts - self.first_ts).total_seconds()
        head = f"{self.samples} samples over {human(span)}"
        if self.gaps:
            head += f", {self.gaps} with mpv not running"
        out = [head]
        for key in self.order():
            label = KNOWN.get(key, (key,))[0]
            rate = self.rate_per_hour(key)
            out.append(f"  {label:<10} first {self.first[key]:>8.1f}"
                       f"  last {self.hist[key][-1]:>8.1f}"
                       f"  min {self.trough[key]:>8.1f}"
                       f"  max {self.peak[key]:>8.1f}"
                       + (f"  {rate:+.1f}/h" if rate is not None else ""))
        return out


def main():
    ap = argparse.ArgumentParser(
        description="Live dashboard for a player-stats feed on stdin.")
    ap.add_argument("--log", metavar="FILE",
                    help="also append the raw feed here (on this machine)")
    ap.add_argument("--plain", action="store_true",
                    help="no redraw; echo lines through and summarise at the end")
    ap.add_argument("--no-colour", action="store_true", help="disable ANSI colour")
    args = ap.parse_args()

    tty = sys.stdout.isatty()
    colour = Colour(tty and not args.no_colour)
    monitor = Monitor(colour)
    plain = args.plain or not tty

    log = open(args.log, "a", buffering=1) if args.log else None
    painted = 0

    if not plain:
        sys.stdout.write("\x1b[2J\x1b[H")
        sys.stdout.flush()

    try:
        while True:
            # readline() rather than iterating sys.stdin: iteration reads ahead
            # in chunks and would stall the display between samples.
            line = sys.stdin.readline()
            if not line:
                break
            line = ANSI.sub("", line).rstrip("\r\n")
            if log:
                log.write(line + "\n")

            parsed = parse(line)
            if parsed is None:
                if plain and line.strip():
                    print(line, flush=True)
                continue
            monitor.add(*parsed)

            if plain:
                print(line, flush=True)
                continue

            # Repaint in place: home the cursor, clear each line as it is
            # rewritten, then erase whatever the previous frame left below.
            frame = monitor.render()
            buf = ["\x1b[H"]
            buf += ["\x1b[2K" + text + "\n" for text in frame]
            buf += ["\x1b[2K\n"] * max(0, painted - len(frame))
            painted = len(frame)
            sys.stdout.write("".join(buf))
            sys.stdout.flush()
    except KeyboardInterrupt:
        pass
    finally:
        if log:
            log.close()

    print("\n" + "\n".join(monitor.summary()))


if __name__ == "__main__":
    main()
