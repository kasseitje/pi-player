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

The display is btop-style: one bordered box per metric, each with a multi-row
area graph coloured by value. Boxes and graph height adapt to the terminal, and
metrics are dropped from the bottom of a priority list when the window is short.
"""

import argparse
import re
import shutil
import sys
from collections import deque
from datetime import datetime

# Eighths, for a multi-row area graph. Index 0 is empty, 8 is a full cell.
BLOCKS = " ▁▂▃▄▅▆▇█"
# 2x4 dot cells give four times the vertical resolution of a block, at the cost
# of needing a font with braille coverage.
BRAILLE_BASE = 0x2800
BRAILLE_DOTS = ((0x01, 0x08), (0x02, 0x10), (0x04, 0x20), (0x40, 0x80))

# Box drawing.
TL, TR, BL, BR, HZ, VT = "╭", "╮", "╰", "╯", "─", "│"

# Numeric metrics: key -> (label, unit, decimals, direction, priority).
# direction: "up" = high is bad, "down" = low is bad, "flat" = neither.
# priority orders which boxes survive on a short terminal (lower shows first).
KNOWN = {
    "rss":       ("rss",       "M", 0, "up",   1),
    "cma_free":  ("cma free",  "M", 0, "down", 2),
    "cpu":       ("cpu",       "%", 0, "up",   3),
    "temp":      ("temp",      "C", 1, "up",   4),
    "mem_avail": ("mem avail", "M", 0, "down", 5),
    "swap":      ("swap",      "M", 0, "up",   6),
    "cache":     ("cache",     "M", 0, "flat", 7),
    "pos":       ("pos",       "",  0, "flat", 8),
}
TEXT_KEYS = ("hwdec", "throttled", "file")
DRIFT_KEYS = ("rss", "swap", "mem_avail", "cma_free")

# CmaFree is the number that predicts a decoder stall, and it bottoms out while
# MemAvailable still looks healthy; the SoC soft-throttles from 80 C.
CMA_WARN = 64.0
TEMP_WARN = 80.0

# Green through yellow to red, in the xterm-256 cube. Truecolor would be
# smoother but 256 is what every terminal worth supporting actually has.
RAMP = [46, 82, 118, 154, 190, 226, 220, 214, 208, 202, 196]
COOL = 39      # neutral metrics
DIMC = 244     # borders and footnotes

TIMESTAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (.*)$")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


class Theme:
    def __init__(self, enabled):
        self.on = enabled

    def fg(self, text, code):
        return f"\x1b[38;5;{code}m{text}\x1b[0m" if self.on else text

    def bold(self, text):
        return f"\x1b[1m{text}\x1b[0m" if self.on else text

    def dim(self, text):
        return self.fg(text, DIMC)

    def ramp(self, text, t, direction):
        """Colour by where the value sits in its own range, 0..1."""
        if direction == "flat":
            return self.fg(text, COOL)
        if direction == "down":
            t = 1.0 - t
        idx = max(0, min(len(RAMP) - 1, int(t * (len(RAMP) - 1))))
        return self.fg(text, RAMP[idx])


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


def human(seconds):
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}h{m:02d}m" if h else f"{m}m{s:02d}s"


def visible(text):
    return len(ANSI.sub("", text))


def area_graph(values, cols, rows, braille=False):
    """Multi-row area graph occupying exactly `cols` visible columns.

    Returns `rows` lists of (char, level 0..1). The level travels with each cell
    so the caller can colour a column by its own height, which is what gives
    btop's graphs their gradient. A braille cell is 2 dots wide, so it carries
    two samples per column and shows twice the history in the same space.
    """
    per_col = 2 if braille else 1
    vals = list(values)[-cols * per_col:]
    if not vals:
        return [[(" ", 0.0)] * cols for _ in range(rows)]

    lo, hi = min(vals), max(vals)
    if hi - lo < 1e-9:
        # A flat series still deserves a visible line rather than an empty box.
        lo, hi = lo - 0.5, hi + 0.5
    span = hi - lo
    norm = [(v - lo) / span for v in vals]

    out = []
    if braille:
        cells = rows * 4
        pairs = [norm[i:i + 2] for i in range(0, len(norm), 2)]
        for r in range(rows - 1, -1, -1):
            line = []
            for pair in pairs:
                bits = 0
                for col, value in enumerate(pair):
                    filled = value * cells - r * 4
                    for dot in range(4):
                        if filled >= dot + 0.5:
                            bits |= BRAILLE_DOTS[3 - dot][col]
                line.append((chr(BRAILLE_BASE + bits), max(pair)))
            out.append(line)
    else:
        for r in range(rows - 1, -1, -1):
            line = [(BLOCKS[max(0, min(8, int(round(v * rows * 8 - r * 8))))], v)
                    for v in norm]
            out.append(line)
    return [[(" ", 0.0)] * (cols - len(line)) + line for line in out]


class Monitor:
    def __init__(self, theme, braille=False, rows=None):
        self.hist = {}
        self.first = {}
        self.peak = {}
        self.trough = {}
        self.text = {}
        self.samples = 0
        self.gaps = 0
        self.first_ts = None
        self.last_ts = None
        self.t = theme
        self.braille = braille
        self.forced_rows = rows
        self.depth = 800

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
        keys = sorted((k for k in self.hist if k in KNOWN), key=lambda k: KNOWN[k][4])
        keys += sorted(k for k in self.hist if k not in KNOWN)
        # A metric flat at zero all run is noise, not information - swap on a
        # healthy board is the whole reason for this. It comes back by itself
        # the moment it goes non-zero.
        return [k for k in keys if self.peak[k] or self.trough[k]]

    def rate_per_hour(self, key):
        """Change per hour over the run - the number that separates a leak from
        warm-up. None until the run is long enough for it to mean anything."""
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

    # ---- drawing ----------------------------------------------------------

    def _top(self, title, right, width):
        """╭─ title ────────────── right ─╮ occupying exactly `width` columns."""
        t = self.t
        left = f"{TL}{HZ} {title} "
        tail = f" {right} {HZ}{TR}" if right else f"{HZ}{TR}"
        fill = max(0, width - len(left) - visible(tail))
        out = t.dim(TL + HZ + " ") + t.bold(t.fg(title, COOL)) + " " + t.dim(HZ * fill)
        if right:
            out += " " + right + " "
        return out + t.dim(HZ + TR)

    def _bottom(self, note, width):
        t = self.t
        if not note:
            return t.dim(BL + HZ * (width - 2) + BR)
        note = note[: max(0, width - 8)]
        left = f"{BL}{HZ} {note} "
        fill = max(0, width - len(left) - 2)
        return t.dim(left + HZ * fill + HZ + BR)

    def _row(self, content, pad, width):
        """│ content …padding… │"""
        t = self.t
        return t.dim(VT) + " " + content + " " * max(0, pad) + " " + t.dim(VT)

    def _box(self, key, width, rows):
        t = self.t
        label, unit, decimals, direction, _ = KNOWN.get(key, (key, "", 0, "flat", 99))
        values = self.hist[key]
        now = values[-1]

        value_txt = f"{now:.{decimals}f}{unit}"
        lo, hi = self.trough[key], self.peak[key]
        pos = 0.0 if hi - lo < 1e-9 else (now - lo) / (hi - lo)
        if key == "cma_free" and now < CMA_WARN:
            headline = t.fg(value_txt, 196)
        elif key == "temp" and now >= TEMP_WARN:
            headline = t.fg(value_txt, 196)
        else:
            headline = t.bold(t.ramp(value_txt, pos, direction))

        inner = width - 4
        lines = [self._top(label, headline, width)]
        for row in area_graph(values, inner, rows, self.braille):
            cells = "".join(t.ramp(ch, lvl, direction) if ch != " " else " "
                            for ch, lvl in row)
            lines.append(self._row(cells, inner - len(row), width))

        if key in DRIFT_KEYS:
            note = f"start {self.first[key]:.0f}{unit}  peak {self.peak[key]:.0f}{unit}  Δ {now - self.first[key]:+.0f}{unit}"
            rate = self.rate_per_hour(key)
            if rate is not None:
                note += f"  {rate:+.0f}{unit}/h"
        elif key == "pos":
            note = f"playlist position  min {lo:.0f}  max {hi:.0f}"
        else:
            note = f"min {lo:.{decimals}f}{unit}  max {hi:.{decimals}f}{unit}"
        lines.append(self._bottom(note, width))
        return lines

    def render(self):
        t = self.t
        size = shutil.get_terminal_size((100, 30))
        width, height = max(48, size.columns), size.lines
        lines = []

        run = human((self.last_ts - self.first_ts).total_seconds())
        right = t.dim(f"{self.last_ts:%H:%M:%S} · {self.samples} samples · {run}")
        lines.append(self._top("pi-player", right, width))
        for key in TEXT_KEYS:
            if key in self.text:
                value = self.text[key]
                inner = width - 4
                val = value[: max(0, inner - 10)]
                lines.append(self._row(t.dim(f"{key:<10}") + val,
                                       inner - 10 - len(val), width))
        lines.append(self._bottom("", width))

        keys = self.order()
        if not keys:
            lines.append(t.dim("  waiting for a sample with fields..."))
            return lines

        alerts = self.alerts()
        # Each box costs 2 borders + graph rows. Fit as many as the window
        # allows, tallest graphs first, then drop the least important metrics.
        budget = height - len(lines) - len(alerts) - 2
        rows = self.forced_rows
        if rows is None:
            rows = 4
            while rows > 1 and (len(keys) * (rows + 2)) > budget:
                rows -= 1
        while keys and (len(keys) * (rows + 2)) > budget and len(keys) > 1:
            keys.pop()

        for key in keys:
            lines.extend(self._box(key, width, rows))
        for text in alerts:
            lines.append(t.fg("  ! " + text[: width - 6], 214))
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
        description="Live btop-style dashboard for a player-stats feed on stdin.")
    ap.add_argument("--log", metavar="FILE",
                    help="also append the raw feed here (on this machine)")
    ap.add_argument("--plain", action="store_true",
                    help="no redraw; echo lines through and summarise at the end")
    ap.add_argument("--no-colour", action="store_true", help="disable ANSI colour")
    ap.add_argument("--braille", action="store_true",
                    help="finer graphs using braille cells (needs a font with them)")
    ap.add_argument("--rows", type=int, metavar="N",
                    help="graph height per box (default: fit the window)")
    args = ap.parse_args()

    tty = sys.stdout.isatty()
    theme = Theme(tty and not args.no_colour)
    monitor = Monitor(theme, braille=args.braille, rows=args.rows)
    plain = args.plain or not tty

    log = open(args.log, "a", buffering=1) if args.log else None
    painted = 0

    if not plain:
        sys.stdout.write("\x1b[2J\x1b[H\x1b[?25l")   # clear, home, hide cursor
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
        if not plain:
            sys.stdout.write("\x1b[?25h")           # restore the cursor
            sys.stdout.flush()

    print("\n" + "\n".join(monitor.summary()))


if __name__ == "__main__":
    main()
