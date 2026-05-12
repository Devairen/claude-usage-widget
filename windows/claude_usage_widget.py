"""Claude Usage Widget — terminal panel showing real claude.ai 5h + weekly limits.

Polls the (undocumented) claude.ai usage API every 60s using curl_cffi to bypass
Cloudflare's TLS fingerprinting. Auth via your browser session cookie.
"""

import csv
import json
import sys
import time
from collections import deque
from datetime import datetime, timedelta, timezone
from pathlib import Path

from curl_cffi import requests
from rich.console import Console
from rich.live import Live
from rich.panel import Panel
from rich.progress_bar import ProgressBar
from rich.table import Table
from rich.text import Text

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "config.json"
HISTORY_PATH = SCRIPT_DIR / "history.json"
CSV_LOG_PATH = SCRIPT_DIR / "usage-log.csv"
CODE_LOGS_DIR = Path.home() / ".claude" / "projects"

POLL_SECONDS = 60
HISTORY_LEN = 60
SPARK_WIDTH = 30
NOTIFY_THRESHOLDS = (80.0, 95.0)
COOKIE_WARN_DAYS = 25

ACCENT_BLUE = "#1C69D4"
ACCENT_DARK = "#0653B6"
ACCENT_RED = "#E22718"


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        sys.stderr.write(
            f"\nMissing {CONFIG_PATH}\n"
            "Copy config.example.json to config.json and fill in your org_id + cookie.\n"
            "See README.md for instructions.\n\n"
        )
        sys.exit(1)
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


def fetch_usage(config: dict) -> tuple[dict | None, str | None]:
    url = f"https://claude.ai/api/organizations/{config['org_id']}/usage"
    headers = {
        "Cookie": config["cookie"],
        "Accept": "*/*",
        "Referer": "https://claude.ai/settings/usage",
        "Sec-Ch-Ua": '"Google Chrome";v="147", "Not.A/Brand";v="8", "Chromium";v="147"',
        "Sec-Ch-Ua-Mobile": "?0",
        "Sec-Ch-Ua-Platform": '"Windows"',
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
    }
    try:
        r = requests.get(url, headers=headers, impersonate="chrome131", timeout=15)
        if r.status_code == 200:
            return r.json(), None
        if r.status_code in (401, 403):
            return None, f"AUTH FAILED ({r.status_code}) - refresh cookie"
        return None, f"HTTP {r.status_code}"
    except Exception as e:
        return None, f"NET ERROR: {type(e).__name__}"


def fmt_reset(iso_str: str | None) -> tuple[str, str]:
    if not iso_str:
        return "-", "-"
    dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
    now = datetime.now(timezone.utc)
    delta = dt - now
    secs = int(delta.total_seconds())
    if secs < 0:
        return "now", dt.astimezone().strftime("%H:%M")
    h, rem = divmod(secs, 3600)
    m, _ = divmod(rem, 60)
    if h >= 24:
        d, h_rem = divmod(h, 24)
        rel = f"{d}d {h_rem}h"
    elif h > 0:
        rel = f"{h}h {m}m"
    else:
        rel = f"{m}m"
    return rel, dt.astimezone().strftime("%a %H:%M")


def color_for(pct: float) -> str:
    if pct >= 66:
        return f"bold {ACCENT_RED}"
    if pct >= 33:
        return f"bold {ACCENT_DARK}"
    return f"bold {ACCENT_BLUE}"


def save_history(history: deque) -> None:
    try:
        HISTORY_PATH.write_text(json.dumps(list(history)), encoding="utf-8")
    except Exception:
        pass


def load_history() -> deque:
    try:
        raw = json.loads(HISTORY_PATH.read_text(encoding="utf-8"))
        cutoff = int(time.time()) // POLL_SECONDS - HISTORY_LEN
        recent = [(int(t), float(p)) for t, p in raw if int(t) >= cutoff]
        return deque(recent, maxlen=HISTORY_LEN)
    except Exception:
        return deque(maxlen=HISTORY_LEN)


SPARK_CHARS = "▁▂▃▄▅▆▇█"


def sparkline(values: list[float], width: int) -> str:
    if not values:
        return ""
    if len(values) > width:
        values = values[-width:]
    lo, hi = min(values), max(values)
    span = hi - lo if hi > lo else 1.0
    return "".join(SPARK_CHARS[int(((v - lo) / span) * (len(SPARK_CHARS) - 1))] for v in values)


def cookie_age_days() -> int | None:
    try:
        return int((time.time() - CONFIG_PATH.stat().st_mtime) / 86400)
    except Exception:
        return None


_notified: set[float] = set()


def maybe_notify(pct: float) -> None:
    for threshold in NOTIFY_THRESHOLDS:
        if pct >= threshold and threshold not in _notified:
            _notified.add(threshold)
            try:
                from windows_toasts import Toast, WindowsToaster

                toaster = WindowsToaster("Claude Usage")
                toast = Toast()
                toast.text_fields = [
                    f"5h session at {pct:.0f}%",
                    f"You crossed the {threshold:.0f}% threshold.",
                ]
                toaster.show_toast(toast)
            except Exception:
                pass


def reset_notifications_if_session_reset(history: deque) -> None:
    if len(history) < 2:
        return
    if history[-2][1] - history[-1][1] > 30:
        _notified.clear()


def append_csv(five_pct: float, week_pct: float) -> None:
    try:
        is_new = not CSV_LOG_PATH.exists()
        with CSV_LOG_PATH.open("a", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            if is_new:
                w.writerow(["timestamp", "five_hour_pct", "weekly_pct"])
            w.writerow([
                datetime.now().isoformat(timespec="seconds"),
                f"{five_pct:.2f}",
                f"{week_pct:.2f}",
            ])
    except Exception:
        pass


def code_burn_rate(window_minutes: int = 10) -> tuple[int, int] | None:
    """Optional: scans Claude Code's local logs for token burn rate.

    Returns None if Claude Code isn't installed or no recent activity.
    """
    if not CODE_LOGS_DIR.exists():
        return None
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=window_minutes)
    total_tokens = 0
    sessions = set()
    try:
        for jsonl in CODE_LOGS_DIR.rglob("*.jsonl"):
            try:
                if jsonl.stat().st_mtime < cutoff.timestamp():
                    continue
                with jsonl.open("r", encoding="utf-8", errors="ignore") as f:
                    for line in f:
                        if '"usage"' not in line:
                            continue
                        try:
                            entry = json.loads(line)
                        except Exception:
                            continue
                        ts_str = entry.get("timestamp")
                        if not ts_str:
                            continue
                        try:
                            ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                        except Exception:
                            continue
                        if ts < cutoff:
                            continue
                        usage = (entry.get("message") or {}).get("usage") or {}
                        tokens = (
                            (usage.get("input_tokens") or 0)
                            + (usage.get("output_tokens") or 0)
                            + (usage.get("cache_read_input_tokens") or 0)
                            + (usage.get("cache_creation_input_tokens") or 0)
                        )
                        total_tokens += tokens
                        sid = entry.get("sessionId")
                        if sid:
                            sessions.add(sid)
            except Exception:
                continue
    except Exception:
        return None
    return (total_tokens, len(sessions))


def render(data: dict | None, err: str | None, history: deque, last_ok: str | None) -> Panel:
    title = Text(" CLAUDE USAGE ", style=f"bold {ACCENT_RED} on black")

    if err and not data:
        body = Table.grid(expand=True)
        body.add_column()
        body.add_row(Text(f"\n  !  {err}\n", style=f"bold {ACCENT_RED}"))
        if last_ok:
            body.add_row(Text(f"  Last good fetch: {last_ok}", style="dim"))
        body.add_row(Text(f"\n  Edit cookie at: {CONFIG_PATH.name}", style="dim"))
        body.add_row(Text(f"  Retrying every {POLL_SECONDS}s...\n", style="dim"))
        return Panel(body, title=title, border_style=ACCENT_RED, padding=(1, 2))

    five = data["five_hour"]
    week = data["seven_day"]
    sonnet = data.get("seven_day_sonnet")
    opus = data.get("seven_day_opus")
    design = data.get("seven_day_omelette")
    extra = data.get("extra_usage") or {}

    five_pct = float(five.get("utilization") or 0)
    week_pct = float(week.get("utilization") or 0)
    five_rel, five_abs = fmt_reset(five.get("resets_at"))
    week_rel, week_abs = fmt_reset(week.get("resets_at"))

    eta_text = "-"
    if len(history) >= 3:
        first_ts, first_pct = history[0]
        last_ts, last_pct = history[-1]
        elapsed_min = (last_ts - first_ts) * (POLL_SECONDS / 60)
        delta_pct = last_pct - first_pct
        if elapsed_min > 0 and delta_pct > 0.1:
            mins_left = max(0.0, 100.0 - last_pct) / (delta_pct / elapsed_min)
            if mins_left < 60:
                eta_text = f"~{int(mins_left)}m at current rate"
            elif mins_left < 24 * 60:
                eta_text = f"~{int(mins_left/60)}h {int(mins_left%60)}m at current rate"
            else:
                eta_text = "well past reset"
        elif delta_pct <= 0.1:
            eta_text = "idle"

    spark_values = [p for _, p in list(history)[-SPARK_WIDTH:]]
    spark = sparkline(spark_values, SPARK_WIDTH) if spark_values else ""

    from rich.console import Group

    sections: list = []

    def make_grid() -> Table:
        g = Table.grid(expand=True, padding=(0, 1))
        g.add_column(width=14, no_wrap=True)
        g.add_column(ratio=1)
        g.add_column(width=14, justify="right", no_wrap=True)
        return g

    def header(text: str) -> Text:
        return Text(text, style=f"bold {ACCENT_BLUE}")

    def bar_row(g: Table, label: str, pct: float, suffix: str):
        bar = ProgressBar(
            total=100,
            completed=pct,
            width=None,
            complete_style=color_for(pct),
            finished_style=f"bold {ACCENT_RED}",
            style="grey23",
        )
        g.add_row(Text(label, style="bold"), bar, Text(suffix, style=color_for(pct)))

    g1 = make_grid()
    bar_row(g1, "Used", five_pct, f"{five_pct:.1f}%")
    g1.add_row(Text("Resets in", style="dim"), Text(f"{five_rel}  ({five_abs})", style="white"), Text(""))
    g1.add_row(Text("ETA full", style="dim"), Text(eta_text, style="white"), Text(""))
    if spark:
        g1.add_row(
            Text("Trend", style="dim"),
            Text(spark, style=ACCENT_DARK),
            Text(f"{len(spark_values)*POLL_SECONDS//60}m", style="dim"),
        )
    sections.append((header("CURRENT 5H SESSION"), g1))

    g2 = make_grid()
    bar_row(g2, "All models", week_pct, f"{week_pct:.1f}%")
    g2.add_row(Text("Resets in", style="dim"), Text(f"{week_rel}  ({week_abs})", style="white"), Text(""))
    if sonnet and sonnet.get("utilization") is not None:
        bar_row(g2, "Sonnet", float(sonnet["utilization"]), f"{float(sonnet['utilization']):.1f}%")
    if opus and opus.get("utilization") is not None:
        bar_row(g2, "Opus", float(opus["utilization"]), f"{float(opus['utilization']):.1f}%")
    if design and design.get("utilization") is not None:
        bar_row(g2, "Design", float(design["utilization"]), f"{float(design['utilization']):.1f}%")
    sections.append((header("WEEKLY (7D)"), g2))

    if extra.get("is_enabled"):
        g3 = make_grid()
        used = extra.get("used_credits") or 0
        limit = extra.get("monthly_limit") or 0
        cur = extra.get("currency") or ""
        if limit:
            bar_row(g3, "Spend", (used / limit) * 100, f"{used:.2f}/{limit:.0f} {cur}")
        sections.append((header("EXTRA USAGE"), g3))

    burn = code_burn_rate()
    if burn and burn[0] > 0:
        tokens, sessions = burn
        g4 = make_grid()
        g4.add_row(
            Text("Tokens used", style="dim"),
            Text(f"{tokens:,}", style="white"),
            Text(f"{tokens//10:,}/m", style="dim"),
        )
        if sessions:
            g4.add_row(Text("Sessions", style="dim"), Text(str(sessions), style="white"), Text(""))
        sections.append((header("CODE BURN RATE (10m)"), g4))

    age = cookie_age_days()
    cookie_warn = f"  ·  cookie {age}d old" if (age is not None and age >= COOKIE_WARN_DAYS) else ""

    foot = f"updated {datetime.now().strftime('%H:%M:%S')}"
    if err:
        foot += f"  ·  ! {err}"
    foot += cookie_warn
    foot_style = ACCENT_RED if cookie_warn else "dim"

    pieces: list = []
    for i, (h, g) in enumerate(sections):
        if i > 0:
            pieces.append(Text(""))
        pieces.append(h)
        pieces.append(g)
    pieces.append(Text(""))
    pieces.append(Text(foot, style=foot_style))

    return Panel(Group(*pieces), title=title, border_style=ACCENT_RED, padding=(1, 2))


def poll_and_record(history: deque) -> tuple[dict | None, str | None]:
    config = load_config()
    data, err = fetch_usage(config)
    if data:
        five_pct = float(data["five_hour"].get("utilization") or 0)
        week_pct = float(data["seven_day"].get("utilization") or 0)
        bucket = int(time.time()) // POLL_SECONDS
        if not history or history[-1][0] != bucket:
            history.append((bucket, five_pct))
            save_history(history)
        append_csv(five_pct, week_pct)
        reset_notifications_if_session_reset(history)
        maybe_notify(five_pct)
    return data, err


def main():
    console = Console()
    history = load_history()
    last_data, last_err = poll_and_record(history)
    last_ok = datetime.now().strftime("%H:%M:%S") if last_data else None

    with Live(
        render(last_data, last_err, history, last_ok),
        console=console,
        refresh_per_second=1,
        screen=False,
    ) as live:
        last_poll = time.time()
        while True:
            now = time.time()
            if now - last_poll >= POLL_SECONDS:
                data, err = poll_and_record(history)
                if data:
                    last_data = data
                    last_ok = datetime.now().strftime("%H:%M:%S")
                    last_err = None
                else:
                    last_err = err
                last_poll = now
            live.update(render(last_data, last_err, history, last_ok))
            time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
