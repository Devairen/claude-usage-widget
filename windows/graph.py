"""Generate a usage graph from usage-log.csv.

Reads the running CSV log and produces usage-graph.png — a 2-panel chart
showing the 5h session % and weekly % over time.

Usage:
    python graph.py            # last 7 days
    python graph.py --days 30  # last N days
    python graph.py --all      # everything in the log
"""

import argparse
import csv
import sys
from datetime import datetime, timedelta
from pathlib import Path

try:
    import matplotlib.dates as mdates
    import matplotlib.pyplot as plt
except ImportError:
    sys.stderr.write("matplotlib not installed. Run: pip install matplotlib\n")
    sys.exit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
CSV_PATH = SCRIPT_DIR / "usage-log.csv"
OUT_PATH = SCRIPT_DIR / "usage-graph.png"

ACCENT_BLUE = "#1C69D4"
ACCENT_DARK = "#0653B6"
ACCENT_RED = "#E22718"


def load_rows(since: datetime | None) -> list[tuple[datetime, float, float]]:
    if not CSV_PATH.exists():
        sys.stderr.write(f"No log found at {CSV_PATH}\n")
        sys.stderr.write("Run the widget for a while to accumulate data first.\n")
        sys.exit(1)
    rows: list[tuple[datetime, float, float]] = []
    with CSV_PATH.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            try:
                ts = datetime.fromisoformat(r["timestamp"])
            except Exception:
                continue
            if since and ts < since:
                continue
            try:
                five = float(r["five_hour_pct"])
                week = float(r["weekly_pct"])
            except Exception:
                continue
            rows.append((ts, five, week))
    return rows


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--days", type=int, default=7, help="window in days (default 7)")
    g.add_argument("--all", action="store_true", help="plot the entire log")
    args = ap.parse_args()

    since = None if args.all else datetime.now() - timedelta(days=args.days)
    rows = load_rows(since)

    if not rows:
        sys.stderr.write("No data points in selected range.\n")
        sys.exit(1)

    times = [r[0] for r in rows]
    five = [r[1] for r in rows]
    week = [r[2] for r in rows]

    plt.style.use("dark_background")
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 7), sharex=True)
    fig.patch.set_facecolor("#0a0a0a")

    for ax in (ax1, ax2):
        ax.set_facecolor("#0a0a0a")
        ax.grid(True, alpha=0.15, linestyle="--")
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
        ax.spines["left"].set_color("#444")
        ax.spines["bottom"].set_color("#444")
        ax.tick_params(colors="#aaa")
        ax.set_ylim(0, 100)
        ax.axhline(80, color=ACCENT_DARK, alpha=0.3, linestyle=":", linewidth=0.8)
        ax.axhline(95, color=ACCENT_RED, alpha=0.3, linestyle=":", linewidth=0.8)

    ax1.plot(times, five, color=ACCENT_BLUE, linewidth=1.5)
    ax1.fill_between(times, 0, five, color=ACCENT_BLUE, alpha=0.2)
    ax1.set_ylabel("5h session %", color="#ddd", fontsize=11)
    ax1.set_title("CLAUDE USAGE", color=ACCENT_RED, fontsize=14, fontweight="bold", pad=12)

    ax2.plot(times, week, color=ACCENT_DARK, linewidth=1.5)
    ax2.fill_between(times, 0, week, color=ACCENT_DARK, alpha=0.2)
    ax2.set_ylabel("weekly %", color="#ddd", fontsize=11)

    span = times[-1] - times[0]
    if span <= timedelta(days=2):
        locator = mdates.HourLocator(interval=max(1, int(span.total_seconds() / 3600 / 12)))
        formatter = mdates.DateFormatter("%a %H:%M")
    elif span <= timedelta(days=14):
        locator = mdates.DayLocator()
        formatter = mdates.DateFormatter("%a %d %b")
    else:
        locator = mdates.AutoDateLocator()
        formatter = mdates.DateFormatter("%d %b")

    ax2.xaxis.set_major_locator(locator)
    ax2.xaxis.set_major_formatter(formatter)
    plt.setp(ax2.xaxis.get_majorticklabels(), rotation=30, ha="right")

    range_label = "all data" if args.all else f"last {args.days}d"
    fig.text(
        0.99, 0.01,
        f"{range_label}  ·  {len(rows):,} samples  ·  generated {datetime.now().strftime('%Y-%m-%d %H:%M')}",
        color="#666", fontsize=8, ha="right",
    )

    plt.tight_layout()
    plt.savefig(OUT_PATH, dpi=130, facecolor="#0a0a0a", bbox_inches="tight")
    print(f"Saved: {OUT_PATH}")
    print(f"  {len(rows):,} samples  ·  {times[0]:%Y-%m-%d %H:%M} -> {times[-1]:%Y-%m-%d %H:%M}")


if __name__ == "__main__":
    main()
