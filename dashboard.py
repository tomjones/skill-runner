#!/usr/bin/env python3
"""skill-runner live dashboard — persistent monitor that watches for runs."""

import json
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from rich.align import Align
from rich.console import Console
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text


def get_running_detail(run_dir: Path, input_name: str) -> dict:
    """Peek at a stream-json result file to get live turn count and last tool used."""
    safe_name = "".join(c if c.isalnum() or c in "._-" else "_" for c in input_name)
    result_file = run_dir / "results" / f"{safe_name}.jsonl"
    detail = {"turns": 0, "last_tool": ""}
    if not result_file.exists():
        return detail
    try:
        lines = result_file.read_text().splitlines()
        for line in reversed(lines):
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
                if obj.get("type") == "assistant" and not detail["last_tool"]:
                    content = obj.get("message", {}).get("content", [])
                    for block in content:
                        if block.get("type") == "tool_use":
                            detail["last_tool"] = block.get("name", "")
                            break
            except json.JSONDecodeError:
                continue
        detail["turns"] = sum(
            1 for l in lines if l.strip() and '"type":"assistant"' in l
        )
    except Exception:
        pass
    return detail


def find_latest_run(runs_dir: Path) -> Path | None:
    """Find the most recent run directory by modification time."""
    dirs = [d for d in runs_dir.glob("*/") if (d / "progress.jsonl").exists()]
    if not dirs:
        return None
    return max(dirs, key=lambda d: d.stat().st_mtime)


def load_meta(run_dir: Path) -> dict:
    """Load run metadata."""
    meta_file = run_dir / "meta.json"
    if meta_file.exists():
        return json.loads(meta_file.read_text())
    return {}


def load_progress(run_dir: Path) -> list[dict]:
    """Load all progress entries."""
    pfile = run_dir / "progress.jsonl"
    if not pfile.exists():
        return []
    entries = []
    for line in pfile.read_text().splitlines():
        line = line.strip()
        if line:
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return entries


def format_duration(secs: int | float) -> str:
    """Format seconds into human-readable duration."""
    secs = int(secs)
    if secs >= 3600:
        return f"{secs // 3600}h {secs % 3600 // 60}m {secs % 60}s"
    elif secs >= 60:
        return f"{secs // 60}m {secs % 60}s"
    return f"{secs}s"


def calc_wall_clock(entries: list[dict]) -> int:
    """Calculate wall clock seconds from first running to last completed timestamp."""
    timestamps = []
    for e in entries:
        ts = e.get("timestamp", "")
        if ts and e.get("status") in ("running", "completed", "failed"):
            try:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                timestamps.append(dt)
            except Exception:
                continue
    if len(timestamps) < 2:
        return sum(e.get("duration_s", 0) for e in entries if e.get("status") in ("completed", "failed"))
    return max(0, int((max(timestamps) - min(timestamps)).total_seconds()))


def is_run_complete(entries: list[dict], total_inputs: int) -> bool:
    """Check if all inputs have a terminal status."""
    if total_inputs == 0:
        return False
    n_done = sum(1 for e in entries if e.get("status") in ("completed", "failed"))
    return n_done >= total_inputs


def is_run_interrupted(run_dir: Path) -> bool:
    """Check if the runner was Ctrl+C'd by looking for 'Interrupted' in run.log."""
    if run_dir is None:
        return False
    log = run_dir / "run.log"
    if not log.exists():
        return False
    try:
        text = log.read_text()
        if "Interrupted" not in text:
            return False
        # Make sure the log is stale (runner has exited)
        return (time.time() - log.stat().st_mtime) > 3
    except Exception:
        return False


def build_interrupted_screen(meta: dict, entries: list[dict], total_inputs: int) -> Layout:
    """Build the red INTERRUPTED screen."""
    status_map: dict[str, dict] = {}
    for e in entries:
        status_map[e.get("input", "")] = e

    completed = [e for e in status_map.values() if e.get("status") == "completed"]
    failed = [e for e in status_map.values() if e.get("status") == "failed"]
    n_done = len(completed) + len(failed)
    remaining = total_inputs - n_done

    total_duration = calc_wall_clock(entries)
    total_cost = sum(e.get("cost_usd", 0) for e in status_map.values())
    total_turns = sum(e.get("turns", 0) for e in status_map.values())

    skill = meta.get("skill", "?")

    text = Text()
    text.append("\n")
    text.append("  RUN INTERRUPTED  \n\n", style="bold white on red")
    text.append(f"  Skill:       {skill}\n", style="bold white on red")
    text.append(f"  Completed:   {len(completed)}\n", style="bold white on red")
    if failed:
        text.append(f"  Failed:      {len(failed)}\n", style="bold yellow on red")
    text.append(f"  Remaining:   {remaining}\n", style="bold white on red")
    text.append(f"  Total:       {total_inputs}\n\n", style="bold white on red")
    text.append(f"  Runtime:     {format_duration(total_duration)}\n", style="white on red")
    text.append(f"  API equiv:   ${total_cost:.4f}\n\n", style="white on red")
    text.append("  Use --resume to continue  ", style="bold white on red")

    layout = Layout()
    layout.update(
        Panel(
            Align.center(text, vertical="middle"),
            style="on red",
            border_style="bold white",
        )
    )
    return layout


def build_idle_screen(sub_limits: dict | None = None) -> Panel:
    """Build the waiting-for-run screen with subscription usage."""
    lines = []
    lines.append("")
    lines.append("  [bold cyan]skill-runner[/bold cyan]")
    lines.append("")
    lines.append("  [dim]Waiting for a run to start...[/dim]")
    lines.append("  [dim]Launch a run in another terminal:[/dim]")
    lines.append("")
    lines.append("  [white]./run --skill /your-skill --workdir ~/your-project --input ...[/white]")
    lines.append("")
    lines.append("  [dim]To resume an interrupted run:[/dim]")
    lines.append("  [white]./run --skill /your-skill --workdir ~/your-project --resume[/white]")
    lines.append("")

    if sub_limits:
        status = sub_limits.get("status", "unknown")
        if status == "allowed":
            status_markup = "[bold green]\u25cf ALLOWED[/bold green]"
        else:
            status_markup = "[bold red]\u25cf BLOCKED[/bold red]"

        util_5h = sub_limits.get("5h_utilization", 0)
        util_7d = sub_limits.get("7d_utilization", 0)

        reset_ts = sub_limits.get("5h_reset", 0)
        reset_info = ""
        if reset_ts:
            reset_dt = datetime.fromtimestamp(reset_ts, tz=timezone.utc)
            now = datetime.now(tz=timezone.utc)
            remaining_secs = max(0, int((reset_dt - now).total_seconds()))
            reset_info = f"  [dim]Resets in[/dim] [bold]{format_duration(remaining_secs)}[/bold]"

        bar_5h = _make_mini_bar(int(util_5h * 100), 100, width=25)
        bar_7d = _make_mini_bar(int(util_7d * 100), 100, width=25)

        lines.append(f"  {status_markup}{reset_info}")
        lines.append(f"  [bold]5-Hour[/bold]   {bar_5h}")
        lines.append(f"  [bold]7-Day[/bold]    {bar_7d}")
    else:
        lines.append("  [dim]Loading subscription usage...[/dim]")

    lines.append("")
    lines.append("  [dim]Ctrl+C to exit[/dim]")
    lines.append("")

    markup = "\n".join(lines)
    content = Text.from_markup(markup)

    return Panel(content, border_style="dim", title="skill-runner", title_align="left")


def build_complete_screen(meta: dict, entries: list[dict], total_inputs: int) -> Layout:
    """Build the big green COMPLETE screen with green background."""
    completed = [e for e in entries if e.get("status") == "completed"]
    failed = [e for e in entries if e.get("status") == "failed"]

    total_duration = calc_wall_clock(entries)
    total_cost = sum(e.get("cost_usd", 0) for e in entries)
    total_turns = sum(e.get("turns", 0) for e in entries)
    avg_duration = total_duration / len(completed) if completed else 0

    skill = meta.get("skill", "?")

    text = Text()
    text.append("\n")
    text.append("  RUN COMPLETE  \n\n", style="bold white on green")
    text.append(f"  Skill:       {skill}\n", style="bold white on green")
    text.append(f"  Completed:   {len(completed)}\n", style="bold white on green")
    if failed:
        text.append(f"  Failed:      {len(failed)}\n", style="bold red on green")
    text.append(f"  Total:       {total_inputs}\n\n", style="bold white on green")
    text.append(f"  Runtime:     {format_duration(total_duration)}\n", style="white on green")
    text.append(f"  Avg/input:   {format_duration(int(avg_duration))}\n", style="white on green")
    text.append(f"  Turns:       {total_turns}\n", style="white on green")
    text.append(f"  API equiv:   ${total_cost:.4f}\n\n", style="white on green")
    text.append("  Waiting for next run...  ", style="bold black on green")

    # Full-screen green layout
    layout = Layout()
    layout.update(
        Panel(
            Align.center(text, vertical="middle"),
            style="on green",
            border_style="bold white",
        )
    )
    return layout


def build_display(
    meta: dict,
    entries: list[dict],
    total_inputs: int,
    all_inputs: list[str],
    run_dir: Path = None,
    usage: dict = None,
    sub_limits: dict = None,
) -> Layout:
    """Build the Rich layout from current state."""

    # Build status map — latest status per input
    status_map: dict[str, dict] = {}
    for e in entries:
        status_map[e.get("input", "")] = e

    completed = [e for e in status_map.values() if e.get("status") == "completed"]
    failed = [e for e in status_map.values() if e.get("status") == "failed"]
    running = [e for e in status_map.values() if e.get("status") == "running"]

    n_completed = len(completed)
    n_failed = len(failed)
    n_running = len(running)
    n_done = n_completed + n_failed
    remaining = total_inputs - n_done

    # -- Header --
    skill = meta.get("skill", "?")
    workdir = meta.get("workdir", "?")
    model = meta.get("model", "?")
    effort = meta.get("effort", "?")
    max_turns = meta.get("max_turns", "?")

    header_text = Text()
    header_text.append("  skill-runner", style="bold cyan")
    header_text.append(f"  {skill}\n", style="bold white")
    header_text.append(f"  workdir: {workdir}\n", style="dim")
    header_text.append(f"  model: {model}  effort: {effort}  max-turns: {max_turns}", style="dim")

    # -- Progress bar --
    pct = (n_done / total_inputs * 100) if total_inputs > 0 else 0
    bar_width = 40
    filled = int(bar_width * n_done / total_inputs) if total_inputs > 0 else 0
    bar = "[green]" + "\u2588" * filled + "[/green]" + "[dim]" + "\u2591" * (bar_width - filled) + "[/dim]"

    # ETA calculation — use wall clock for runtime, but per-task avg for ETA
    total_duration = calc_wall_clock(entries)
    avg_task_duration = (
        sum(e.get("duration_s", 0) for e in completed + failed) / n_done
        if n_done > 0 else 0
    )
    avg_duration = total_duration / n_done if n_done > 0 else 0
    eta_secs = int(avg_duration * remaining)
    eta_str = format_duration(eta_secs) if n_done > 0 else "calculating..."

    progress_text = Text()
    progress_text.append(f"\n  {bar}  {pct:.0f}%  {n_done}/{total_inputs}  ETA {eta_str}\n\n")
    progress_text.append(f"  [green]\u2713[/green] Completed {n_completed}    ")
    progress_text.append(f"[red]\u2717[/red] Failed {n_failed}    ")
    progress_text.append(f"[yellow]\u25b8[/yellow] Running {n_running}    ")
    progress_text.append(f"[dim]Remaining {remaining}[/dim]")

    progress_panel = Panel(
        Text.from_markup(str(progress_text)),
        title="Progress",
        border_style="blue",
    )

    # -- Stats --
    total_cost = sum(e.get("cost_usd", 0) for e in status_map.values())
    total_turns = sum(e.get("turns", 0) for e in status_map.values())
    avg_turns = total_turns / n_done if n_done > 0 else 0

    runtime_str = format_duration(total_duration)

    cost_str = f"${total_cost:.4f}"
    stats_text = (
        f"  API equiv:     {cost_str:<20}Avg/task:     {format_duration(int(avg_task_duration))}\n"
        f"  Total turns:   {total_turns:<20}Avg turns:    {avg_turns:.1f}\n"
        f"  Total runtime: {runtime_str:<20}Est remaining: {format_duration(eta_secs)}"
    )

    stats_panel = Panel(stats_text, title="Performance", border_style="blue")

    # -- All inputs table (windowed) --
    task_table = Table(
        show_header=True, header_style="bold", expand=True, show_lines=False, padding=(0, 1)
    )
    task_table.add_column("#", justify="right", width=4, style="dim")
    task_table.add_column("", width=2)
    task_table.add_column("Input", min_width=14)
    task_table.add_column("Status", width=12)
    task_table.add_column("Turns", justify="right", width=6)
    task_table.add_column("Cost", justify="right", width=8)
    task_table.add_column("Started", justify="right", width=10)
    task_table.add_column("Finished", justify="right", width=10)

    # Build start time map from "running" entries
    start_time_map: dict[str, str] = {}
    for e in entries:
        if e.get("status") == "running":
            start_time_map[e.get("input", "")] = e.get("timestamp", "")

    # Find focus row (first running or first pending)
    focus_idx = len(all_inputs) - 1  # default to end
    for i, inp in enumerate(all_inputs):
        s = status_map.get(inp, {}).get("status")
        if s == "running" or s is None:  # None = pending (not in status_map)
            focus_idx = i
            break

    # Window: show ~10 visible rows, with 3 completed above the focus
    visible_rows = 10
    context_above = min(3, focus_idx)
    start = max(0, focus_idx - context_above)
    end = min(len(all_inputs), start + visible_rows)
    if end == len(all_inputs):
        start = max(0, end - visible_rows)

    hidden_above = start
    hidden_below = len(all_inputs) - end

    # Scroll indicator: above
    if hidden_above > 0:
        task_table.add_row(
            "", "", f"[dim]\u2191 {hidden_above} completed above[/dim]",
            "", "", "", "", "",
        )

    # Render windowed rows
    for idx in range(start, end):
        inp = all_inputs[idx]
        row_num = idx + 1
        e = status_map.get(inp)

        if e is None:
            task_table.add_row(
                str(row_num), "[dim]\u2022[/dim]", f"[dim]{inp}[/dim]",
                "[dim]pending[/dim]", "", "", "", "",
            )
            continue

        status = e.get("status", "?")
        ts = e.get("timestamp", "")
        started_ts = start_time_map.get(inp, "")
        started_str = started_ts[11:19] if len(started_ts) >= 19 else ""
        finished_str = ts[11:19] if len(ts) >= 19 else ""

        if status == "completed":
            icon = "[green]\u2713[/green]"
            status_text = "[green]completed[/green]"
            task_table.add_row(
                str(row_num), icon, inp, status_text,
                str(e.get("turns", 0)),
                f"${e.get('cost_usd', 0):.4f}",
                started_str,
                finished_str,
            )
        elif status == "failed":
            icon = "[red]\u2717[/red]"
            status_text = "[red]failed[/red]"
            task_table.add_row(
                str(row_num), icon, f"[red]{inp}[/red]", status_text,
                str(e.get("turns", 0)),
                f"${e.get('cost_usd', 0):.4f}",
                started_str,
                f"[red]{finished_str}[/red]",
            )
        elif status == "running":
            spinner_chars = "\u280b\u2819\u2839\u2838\u283c\u2834\u2826\u2827"
            spinner = spinner_chars[int(time.time() * 2) % len(spinner_chars)]
            icon = f"[yellow]{spinner}[/yellow]"
            detail = get_running_detail(run_dir, inp) if run_dir else {}
            live_turns = detail.get("turns", 0)
            last_tool = detail.get("last_tool", "")
            tool_text = f" [dim]({last_tool})[/dim]" if last_tool else ""
            status_text = f"[yellow bold]running[/yellow bold]{tool_text}"
            # Live elapsed in Finished column
            elapsed_str = ""
            if started_ts:
                try:
                    started_dt = datetime.fromisoformat(started_ts.replace("Z", "+00:00"))
                    elapsed_secs = max(0, int((datetime.now(tz=timezone.utc) - started_dt).total_seconds()))
                    elapsed_str = f"[yellow]{format_duration(elapsed_secs)}[/yellow]"
                except Exception:
                    elapsed_str = "[yellow]...[/yellow]"
            task_table.add_row(
                str(row_num), icon, f"[yellow]{inp}[/yellow]", status_text,
                str(live_turns) if live_turns else "",
                "",
                started_str,
                elapsed_str,
            )
        else:
            task_table.add_row(
                str(row_num), " ", inp, status, "", "", "", "",
            )

    # Scroll indicator: below
    if hidden_below > 0:
        task_table.add_row(
            "", "", f"[dim]\u2193 {hidden_below} more below[/dim]",
            "", "", "", "", "",
        )

    task_panel = Panel(task_table, title=f"Tasks ({n_done}/{total_inputs})", border_style="blue")

    # -- Live log terminal --
    visible_log_lines = 12
    total_log_lines, log_lines = _read_log_tail(run_dir, max_lines=visible_log_lines)
    log_text = Text()

    hidden_log = total_log_lines - len(log_lines)
    if hidden_log > 0:
        log_text.append(f"  \u2191 {hidden_log} lines above\n", style="dim")

    for line in log_lines:
        if "[SUCCESS]" in line:
            log_text.append(line + "\n", style="green")
        elif "[ERROR]" in line:
            log_text.append(line + "\n", style="red")
        elif "[WARN" in line:
            log_text.append(line + "\n", style="yellow")
        elif "[INFO" in line and "Running:" in line:
            log_text.append(line + "\n", style="cyan")
        elif line.startswith("  ["):
            if "] tool:" in line:
                log_text.append(line + "\n", style="dim")
            else:
                log_text.append(line + "\n", style="white")
        else:
            log_text.append(line + "\n", style="dim")

    if not log_lines and total_log_lines == 0:
        log_text.append("  Waiting for output...\n", style="dim")

    log_panel = Panel(
        log_text,
        title="Output",
        border_style="dim white",
        style="on grey7",
    )

    # -- Usage & Limits panel --
    usage_panel = build_usage_panel(usage or {}, sub_limits)
    usage_height = 8 if sub_limits else 6

    # -- Compose layout --
    layout = Layout()
    layout.split_column(
        Layout(Panel(header_text, border_style="cyan"), name="header", size=5),
        Layout(progress_panel, name="progress", size=7),
        Layout(stats_panel, name="stats", size=5),
        Layout(usage_panel, name="usage", size=usage_height),
        Layout(task_panel, name="tasks"),
        Layout(log_panel, name="log", size=15),
    )

    return layout


def _read_log_tail(run_dir: Path | None, max_lines: int = 12) -> tuple[int, list[str]]:
    """Read the last N lines from run.log. Returns (total_lines, tail_lines)."""
    if run_dir is None:
        return 0, []
    log_file = run_dir / "run.log"
    if not log_file.exists():
        return 0, []
    try:
        text = log_file.read_text()
        lines = text.splitlines()
        total = len(lines)
        tail = lines[-max_lines:] if total > max_lines else lines
        return total, tail
    except Exception:
        return 0, []


def get_usage_from_results(run_dir: Path) -> dict:
    """Aggregate token usage and rate limit info from stream-json result files."""
    usage = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_tokens": 0,
        "cache_creation_tokens": 0,
        "rate_limit": None,  # from rate_limit_event
    }
    if run_dir is None:
        return usage

    results_dir = run_dir / "results"
    if not results_dir.exists():
        return usage

    latest_rate_limit = None
    latest_rate_limit_time = 0

    for result_file in results_dir.glob("*.jsonl"):
        try:
            for line in result_file.read_text().splitlines():
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue

                # Aggregate from result events
                if obj.get("type") == "result":
                    u = obj.get("usage", {})
                    usage["input_tokens"] += u.get("input_tokens", 0)
                    usage["output_tokens"] += u.get("output_tokens", 0)
                    usage["cache_read_tokens"] += u.get("cache_read_input_tokens", 0)
                    usage["cache_creation_tokens"] += u.get("cache_creation_input_tokens", 0)

                # Capture rate limit events (keep the most recent)
                if obj.get("type") == "rate_limit_event":
                    mtime = result_file.stat().st_mtime
                    if mtime >= latest_rate_limit_time:
                        latest_rate_limit_time = mtime
                        latest_rate_limit = obj.get("rate_limit_info", {})
        except Exception:
            continue

    usage["rate_limit"] = latest_rate_limit
    return usage




_sub_cache: dict = {}
_sub_cache_time: float = 0.0


def get_subscription_limits() -> dict | None:
    """Read OAuth token from ~/.claude, make minimal Haiku call for subscription rate limits. Cached 60s."""
    global _sub_cache, _sub_cache_time

    if time.time() - _sub_cache_time < 60:
        return _sub_cache or None

    # Read OAuth token
    creds_file = Path.home() / ".claude" / ".credentials.json"
    if not creds_file.exists():
        _sub_cache_time = time.time()
        return None

    try:
        creds = json.loads(creds_file.read_text())
        token = creds.get("claudeAiOauth", {}).get("accessToken")
        if not token:
            _sub_cache_time = time.time()
            return None

        data = json.dumps({
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [{"role": "user", "content": "."}],
        }).encode()

        req = urllib.request.Request(
            "https://api.anthropic.com/v1/messages",
            data=data,
            headers={
                "x-api-key": token,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
        )

        with urllib.request.urlopen(req, timeout=10) as resp:
            h = resp.headers
            _sub_cache = {
                "status": h.get("anthropic-ratelimit-unified-status"),
                "5h_status": h.get("anthropic-ratelimit-unified-5h-status"),
                "5h_utilization": float(h.get("anthropic-ratelimit-unified-5h-utilization", 0)),
                "5h_reset": int(h.get("anthropic-ratelimit-unified-5h-reset", 0)),
                "7d_status": h.get("anthropic-ratelimit-unified-7d-status"),
                "7d_utilization": float(h.get("anthropic-ratelimit-unified-7d-utilization", 0)),
                "7d_reset": int(h.get("anthropic-ratelimit-unified-7d-reset", 0)),
                "overage_status": h.get("anthropic-ratelimit-unified-overage-status"),
                "overage_utilization": float(h.get("anthropic-ratelimit-unified-overage-utilization", 0)),
            }
            _sub_cache_time = time.time()
            return _sub_cache
    except Exception:
        _sub_cache_time = time.time()
        return None


def _make_mini_bar(used: int, total: int, width: int = 20) -> str:
    """Build a small usage bar: [████░░░░] 42%"""
    if total <= 0:
        return ""
    pct = min(used / total, 1.0)
    filled = int(width * pct)
    empty = width - filled
    # Color: green < 60%, yellow 60-85%, red > 85%
    if pct < 0.6:
        color = "green"
    elif pct < 0.85:
        color = "yellow"
    else:
        color = "red"
    filled_bar = "\u2588" * filled
    empty_bar = "\u2591" * empty
    return f"[{color}]{filled_bar}[/{color}][dim]{empty_bar}[/dim] {pct:.0%}"


def build_usage_panel(usage: dict, sub_limits: dict | None = None) -> Panel:
    """Build the Usage & Limits panel with subscription utilization."""
    rl = usage.get("rate_limit")
    lines = []

    # Status line — prefer subscription data, fall back to stream data
    if sub_limits:
        status = sub_limits.get("status", "unknown")
        if status == "allowed":
            status_markup = "[bold green]\u25cf ALLOWED[/bold green]"
        else:
            status_markup = "[bold red]\u25cf BLOCKED[/bold red]"

        reset_ts = sub_limits.get("5h_reset", 0)
        reset_info = ""
        if reset_ts:
            reset_dt = datetime.fromtimestamp(reset_ts, tz=timezone.utc)
            now = datetime.now(tz=timezone.utc)
            remaining_secs = max(0, int((reset_dt - now).total_seconds()))
            reset_info = f"  [dim]Resets in[/dim] [bold]{format_duration(remaining_secs)}[/bold]  [dim]({reset_dt.strftime('%H:%M UTC')})[/dim]"

        lines.append(f"  {status_markup}{reset_info}")

        # Subscription utilization bars
        util_5h = sub_limits.get("5h_utilization", 0)
        util_7d = sub_limits.get("7d_utilization", 0)
        util_ovg = sub_limits.get("overage_utilization", 0)

        bar_5h = _make_mini_bar(int(util_5h * 100), 100, width=25)
        bar_7d = _make_mini_bar(int(util_7d * 100), 100, width=25)

        lines.append(f"  [bold]5-Hour[/bold]   {bar_5h}")
        lines.append(f"  [bold]7-Day[/bold]    {bar_7d}")

        if util_ovg > 0:
            bar_ovg = _make_mini_bar(int(util_ovg * 100), 100, width=25)
            lines.append(f"  [bold]Overage[/bold]  {bar_ovg}  [yellow]\u26a0 active[/yellow]")

    elif rl:
        # Fallback to stream data
        status = rl.get("status", "unknown")
        if status == "allowed":
            status_markup = "[bold green]\u25cf ALLOWED[/bold green]"
        else:
            status_markup = "[bold red]\u25cf BLOCKED[/bold red]"

        resets_at = rl.get("resetsAt")
        reset_info = ""
        if resets_at:
            reset_dt = datetime.fromtimestamp(resets_at, tz=timezone.utc)
            now = datetime.now(tz=timezone.utc)
            remaining_secs = max(0, int((reset_dt - now).total_seconds()))
            reset_info = f"  [dim]Resets in[/dim] [bold]{format_duration(remaining_secs)}[/bold]  [dim]({reset_dt.strftime('%H:%M UTC')})[/dim]"

        lines.append(f"  {status_markup}{reset_info}")
        lines.append("  [dim italic]Waiting for subscription data...[/dim italic]")
    else:
        lines.append("  [dim]\u25cb Waiting for rate limit data...[/dim]")

    # Divider
    lines.append("  [dim]" + "\u2500" * 60 + "[/dim]")

    # Session token breakdown
    inp = usage.get("input_tokens", 0)
    out = usage.get("output_tokens", 0)
    cached = usage.get("cache_read_tokens", 0)
    created = usage.get("cache_creation_tokens", 0)
    total_tok = inp + out + cached + created

    lines.append(
        f"  [bold]Session[/bold]  [white]{total_tok:,}[/white] tokens   "
        f"[cyan]{inp:,}[/cyan] in   "
        f"[magenta]{out:,}[/magenta] out   "
        f"[dim]{cached:,} cached[/dim]"
    )

    markup = "\n".join(lines)
    content = Text.from_markup(markup)

    border = "blue"
    status_val = (sub_limits or {}).get("status") or (rl or {}).get("status")
    if status_val and status_val != "allowed":
        border = "bold red"

    return Panel(content, title="Usage & Limits", border_style=border)


def main():
    script_dir = Path(__file__).parent
    runs_dir = script_dir / "runs"
    runs_dir.mkdir(exist_ok=True)

    # If a specific run dir was passed, lock to it
    pinned_run = Path(sys.argv[1]) if len(sys.argv) > 1 else None

    console = Console()

    with Live(console=console, refresh_per_second=1, screen=True) as live:
        current_run_dir = None
        current_meta = {}
        all_inputs: list[str] = []
        total_inputs = 0
        show_complete = False
        show_interrupted = False
        complete_shown_at = 0.0
        interrupted_shown_at = 0.0

        while True:
            try:
                # -- Discover or re-discover run directory --
                if pinned_run:
                    candidate = pinned_run
                else:
                    candidate = find_latest_run(runs_dir)

                # Detect new run (different directory than what we're tracking)
                if candidate and candidate != current_run_dir:
                    current_run_dir = candidate
                    current_meta = load_meta(current_run_dir)
                    inputs_file = current_run_dir / "inputs.txt"
                    if inputs_file.exists():
                        all_inputs = [l for l in inputs_file.read_text().splitlines() if l.strip()]
                    else:
                        all_inputs = []
                    total_inputs = len(all_inputs)
                    show_complete = False
                    show_interrupted = False

                # -- No run found: idle screen --
                if current_run_dir is None:
                    idle_sub = get_subscription_limits()
                    live.update(build_idle_screen(idle_sub))
                    time.sleep(1)
                    continue

                # -- Load progress --
                entries = load_progress(current_run_dir)
                run_complete = is_run_complete(entries, total_inputs)
                run_interrupted = not run_complete and is_run_interrupted(current_run_dir)

                # -- Interrupted screen --
                if run_interrupted and not show_interrupted:
                    show_interrupted = True
                    interrupted_shown_at = time.time()

                if show_interrupted:
                    elapsed = time.time() - interrupted_shown_at

                    if elapsed < 10:
                        live.update(build_interrupted_screen(current_meta, entries, total_inputs))
                    else:
                        if not pinned_run:
                            newer = find_latest_run(runs_dir)
                            if newer and newer != current_run_dir:
                                current_run_dir = newer
                                current_meta = load_meta(current_run_dir)
                                inputs_file = current_run_dir / "inputs.txt"
                                if inputs_file.exists():
                                    all_inputs = [l for l in inputs_file.read_text().splitlines() if l.strip()]
                                else:
                                    all_inputs = []
                                total_inputs = len(all_inputs)
                                show_interrupted = False
                                continue

                        idle_sub = get_subscription_limits()
                        live.update(build_idle_screen(idle_sub))

                    time.sleep(1)
                    continue

                # -- Complete screen --
                if run_complete and not show_complete:
                    show_complete = True
                    complete_shown_at = time.time()

                if show_complete:
                    elapsed = time.time() - complete_shown_at

                    # Show complete screen for 10 seconds, then go idle
                    if elapsed < 10:
                        live.update(build_complete_screen(current_meta, entries, total_inputs))
                    else:
                        # Check for a newer run to auto-switch
                        if not pinned_run:
                            newer = find_latest_run(runs_dir)
                            if newer and newer != current_run_dir:
                                current_run_dir = newer
                                current_meta = load_meta(current_run_dir)
                                inputs_file = current_run_dir / "inputs.txt"
                                if inputs_file.exists():
                                    all_inputs = [l for l in inputs_file.read_text().splitlines() if l.strip()]
                                else:
                                    all_inputs = []
                                total_inputs = len(all_inputs)
                                show_complete = False
                                continue

                        # Back to idle, waiting for next run
                        idle_sub = get_subscription_limits()
                        live.update(build_idle_screen(idle_sub))

                    time.sleep(1)
                    continue

                # -- Active run: show dashboard --
                usage = get_usage_from_results(current_run_dir)
                sub_limits = get_subscription_limits()
                layout = build_display(current_meta, entries, total_inputs, all_inputs, current_run_dir, usage, sub_limits)
                live.update(layout)

                time.sleep(1)

            except KeyboardInterrupt:
                break


if __name__ == "__main__":
    main()
