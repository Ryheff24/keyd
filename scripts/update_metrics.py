#!/usr/bin/env python3
"""Update .planning/METRICS.md.

This script is the only supported way to edit the metrics markdown.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_METRICS_PATH = REPO_ROOT / ".planning" / "METRICS.md"


@dataclass
class Entry:
    date: str
    time: str
    commit_id: str
    viewport_width: int
    viewport_height: int
    frame_width: int
    frame_height: int
    fps: float
    frame_pacing_cv: float | None
    pipeline_median_ms: float
    pipeline_p95_ms: float
    pipeline_avg_ms: float
    g2g_median_ms: float
    g2g_p95_ms: float
    g2g_avg_ms: float
    heavy_load_fps: float | None
    heavy_load_pipeline_median_ms: float | None
    heavy_load_pipeline_p95_ms: float | None
    security_rejection: int
    overall_passed: int
    overall_total: int
    notes: str


@dataclass
class MetricDef:
    name: str
    accessor: Callable[[Entry], float]
    default_goal: float
    formatter: Callable[[float], str]
    comparator: str  # eq, min, max
    goal_parser: Callable[[str], float]


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def run_git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def parse_resolution(value: str) -> tuple[int, int]:
    match = re.fullmatch(r"(\d+)x(\d+)", value.strip())
    if not match:
        fail(f"resolution must be WIDTHxHEIGHT, got {value!r}")
    return int(match.group(1)), int(match.group(2))


def parse_overall(value: str) -> tuple[int, int]:
    match = re.fullmatch(r"(\d+)/(\d+)", value.strip())
    if not match:
        fail(f"overall must be PASSED/TOTAL, got {value!r}")
    passed = int(match.group(1))
    total = int(match.group(2))
    if total <= 0:
        fail("overall total must be > 0")
    if passed < 0 or passed > total:
        fail("overall passed count must be between 0 and total")
    return passed, total


def parse_optional_float(cell: str) -> float | None:
    cell = cell.strip()
    if cell in {"—", "N/A", ""}:
        return None
    return float(cell)


def parse_compound_latency(cell: str) -> tuple[float, float, float]:
    match = re.fullmatch(
        r"([0-9]+(?:\.[0-9]+)?)/([0-9]+(?:\.[0-9]+)?)/([0-9]+(?:\.[0-9]+)?) ms",
        cell.strip(),
    )
    if not match:
        fail(f"latency cell must be 'median/p95/avg ms', got {cell!r}")
    return float(match.group(1)), float(match.group(2)), float(match.group(3))


def parse_heavy_load(cell: str) -> tuple[float | None, float | None, float | None]:
    cell = cell.strip()
    if cell in {"—", "N/A", ""}:
        return None, None, None
    match = re.fullmatch(
        r"([0-9]+(?:\.[0-9]+)?) fps, ([0-9]+(?:\.[0-9]+)?)/([0-9]+(?:\.[0-9]+)?) ms",
        cell,
    )
    if not match:
        fail(f"heavy-load cell must be 'FPS fps, median/p95 ms', got {cell!r}")
    return float(match.group(1)), float(match.group(2)), float(match.group(3))


def sanitize_notes(notes: str | None) -> str:
    if not notes:
        return "—"
    clean = " ".join(notes.replace("|", "/").split())
    if len(clean) > 120:
        fail("notes must be 120 characters or fewer after whitespace normalization")
    return clean


def canonical_commit_id(raw_commit: str) -> str:
    try:
        run_git("rev-parse", "--verify", f"{raw_commit}^{{commit}}")
    except subprocess.CalledProcessError as exc:
        fail(f"commit ID {raw_commit!r} does not exist in git: {exc.stderr.strip()}")
    return run_git("rev-parse", "--short=7", raw_commit)


def parse_changelog_entries(text: str) -> list[Entry]:
    if "## Changelog" not in text:
        fail("METRICS.md is missing the changelog section")

    lines = text.splitlines()
    in_changelog = False
    entries: list[Entry] = []
    for line in lines:
        if line.strip() == "## Changelog":
            in_changelog = True
            continue
        if not in_changelog:
            continue
        if not line.startswith("|"):
            continue
        if line.startswith("| Date ") or line.startswith("|------"):
            continue
        cells = [cell.strip() for cell in line.strip().split("|")[1:-1]]
        if len(cells) == 12:
            viewport_width, viewport_height = parse_resolution(cells[3].strip("`"))
            frame_width, frame_height = viewport_width, viewport_height
            fps = float(cells[4].strip("`").removesuffix(" fps"))
            frame_pacing_cv = parse_optional_float(cells[5].strip("`"))
            pipeline_median_ms, pipeline_p95_ms, pipeline_avg_ms = parse_compound_latency(
                cells[6].strip("`")
            )
            g2g_median_ms, g2g_p95_ms, g2g_avg_ms = parse_compound_latency(cells[7].strip("`"))
            heavy_fps, heavy_median_ms, heavy_p95_ms = parse_heavy_load(cells[8].strip("`"))
            security_rejection = int(cells[9].strip("`"))
            overall_passed, overall_total = parse_overall(cells[10].strip("`"))
            notes = cells[11]
        elif len(cells) == 13:
            viewport_width, viewport_height = parse_resolution(cells[3].strip("`"))
            frame_width, frame_height = parse_resolution(cells[4].strip("`"))
            fps = float(cells[5].strip("`").removesuffix(" fps"))
            frame_pacing_cv = parse_optional_float(cells[6].strip("`"))
            pipeline_median_ms, pipeline_p95_ms, pipeline_avg_ms = parse_compound_latency(
                cells[7].strip("`")
            )
            g2g_median_ms, g2g_p95_ms, g2g_avg_ms = parse_compound_latency(cells[8].strip("`"))
            heavy_fps, heavy_median_ms, heavy_p95_ms = parse_heavy_load(cells[9].strip("`"))
            security_rejection = int(cells[10].strip("`"))
            overall_passed, overall_total = parse_overall(cells[11].strip("`"))
            notes = cells[12]
        else:
            fail(f"expected 12 or 13 changelog columns, found {len(cells)} in line: {line}")

        entries.append(
            Entry(
                date=cells[0],
                time=cells[1],
                commit_id=cells[2].strip("`"),
                viewport_width=viewport_width,
                viewport_height=viewport_height,
                frame_width=frame_width,
                frame_height=frame_height,
                fps=fps,
                frame_pacing_cv=frame_pacing_cv,
                pipeline_median_ms=pipeline_median_ms,
                pipeline_p95_ms=pipeline_p95_ms,
                pipeline_avg_ms=pipeline_avg_ms,
                g2g_median_ms=g2g_median_ms,
                g2g_p95_ms=g2g_p95_ms,
                g2g_avg_ms=g2g_avg_ms,
                heavy_load_fps=heavy_fps,
                heavy_load_pipeline_median_ms=heavy_median_ms,
                heavy_load_pipeline_p95_ms=heavy_p95_ms,
                security_rejection=security_rejection,
                overall_passed=overall_passed,
                overall_total=overall_total,
                notes=notes,
            )
        )
    return entries


def format_px(value: float) -> str:
    return f"`{int(round(value))} px`"


def format_fps(value: float) -> str:
    return f"`{value:.1f} fps`"


def format_plain(value: float) -> str:
    return f"`{value:.3f}`"


def format_ms(value: float) -> str:
    return f"`{int(round(value))} ms`"


def format_int(value: float) -> str:
    return f"`{int(round(value))}`"


def format_pct(value: float) -> str:
    return f"`{value:.1f}%`"


def parse_goal_px(cell: str) -> float:
    match = re.fullmatch(r"`?(\d+) px`?", cell.strip())
    if not match:
        fail(f"goal cell must be '`N px`', got {cell!r}")
    return float(match.group(1))


def parse_goal_fps(cell: str) -> float:
    match = re.fullmatch(r"`?([0-9]+(?:\.[0-9]+)?) fps`?", cell.strip())
    if not match:
        fail(f"goal cell must be '`N.N fps`', got {cell!r}")
    return float(match.group(1))


def parse_goal_plain(cell: str) -> float:
    match = re.fullmatch(r"`?([0-9]+(?:\.[0-9]+)?)`?", cell.strip())
    if not match:
        fail(f"goal cell must be '`N.NNN`', got {cell!r}")
    return float(match.group(1))


def parse_goal_ms(cell: str) -> float:
    match = re.fullmatch(r"`?([0-9]+(?:\.[0-9]+)?) ms`?", cell.strip())
    if not match:
        fail(f"goal cell must be '`N ms`', got {cell!r}")
    return float(match.group(1))


def parse_goal_int(cell: str) -> float:
    match = re.fullmatch(r"`?(\d+)`?", cell.strip())
    if not match:
        fail(f"goal cell must be '`N`', got {cell!r}")
    return float(match.group(1))


def parse_goal_pct(cell: str) -> float:
    match = re.fullmatch(r"`?([0-9]+(?:\.[0-9]+)?)%`?", cell.strip())
    if not match:
        fail(f"goal cell must be '`N.N%`', got {cell!r}")
    return float(match.group(1))


METRICS: list[MetricDef] = [
    MetricDef("Viewport width", lambda e: e.viewport_width, 2752, format_px, "eq", parse_goal_px),
    MetricDef("Viewport height", lambda e: e.viewport_height, 1786, format_px, "eq", parse_goal_px),
    MetricDef("Delivered frame width", lambda e: e.frame_width, 2752, format_px, "eq", parse_goal_px),
    MetricDef("Delivered frame height", lambda e: e.frame_height, 1786, format_px, "eq", parse_goal_px),
    MetricDef("FPS", lambda e: e.fps, 60.0, format_fps, "max", parse_goal_fps),
    MetricDef(
        "Frame pacing CV",
        lambda e: e.frame_pacing_cv if e.frame_pacing_cv is not None else float("inf"),
        0.350,
        format_plain,
        "min",
        parse_goal_plain,
    ),
    MetricDef("Pipeline latency median", lambda e: e.pipeline_median_ms, 20, format_ms, "min", parse_goal_ms),
    MetricDef("Pipeline latency p95", lambda e: e.pipeline_p95_ms, 50, format_ms, "min", parse_goal_ms),
    MetricDef("Pipeline latency avg", lambda e: e.pipeline_avg_ms, 25, format_ms, "min", parse_goal_ms),
    MetricDef("Glass-to-glass latency median", lambda e: e.g2g_median_ms, 20, format_ms, "min", parse_goal_ms),
    MetricDef("Glass-to-glass latency p95", lambda e: e.g2g_p95_ms, 40, format_ms, "min", parse_goal_ms),
    MetricDef("Glass-to-glass latency avg", lambda e: e.g2g_avg_ms, 25, format_ms, "min", parse_goal_ms),
    MetricDef(
        "Heavy-load FPS",
        lambda e: e.heavy_load_fps if e.heavy_load_fps is not None else float("-inf"),
        30.0,
        format_fps,
        "max",
        parse_goal_fps,
    ),
    MetricDef(
        "Heavy-load pipeline median",
        lambda e: e.heavy_load_pipeline_median_ms
        if e.heavy_load_pipeline_median_ms is not None
        else float("inf"),
        100,
        format_ms,
        "min",
        parse_goal_ms,
    ),
    MetricDef(
        "Heavy-load pipeline p95",
        lambda e: e.heavy_load_pipeline_p95_ms
        if e.heavy_load_pipeline_p95_ms is not None
        else float("inf"),
        150,
        format_ms,
        "min",
        parse_goal_ms,
    ),
    MetricDef("Security rejection", lambda e: float(e.security_rejection), 1, format_int, "eq", parse_goal_int),
    MetricDef(
        "Overall pass rate",
        lambda e: 100.0 * e.overall_passed / e.overall_total,
        100.0,
        format_pct,
        "eq",
        parse_goal_pct,
    ),
]


def parse_summary_goals(text: str) -> dict[str, float]:
    if "## Summary" not in text:
        fail("METRICS.md is missing the summary section")

    metric_by_name = {metric.name: metric for metric in METRICS}
    goals: dict[str, float] = {}
    in_summary = False
    for line in text.splitlines():
        if line.strip() == "## Summary":
            in_summary = True
            continue
        if in_summary and line.startswith("## "):
            break
        if not in_summary or not line.startswith("|"):
            continue
        if line.startswith("| Metric ") or line.startswith("|--------"):
            continue

        cells = [cell.strip() for cell in line.strip().split("|")[1:-1]]
        if len(cells) != 5:
            fail(f"expected 5 summary columns, found {len(cells)} in line: {line}")
        metric_name = cells[0]
        metric = metric_by_name.get(metric_name)
        if metric is None:
            fail(f"unknown metric in summary table: {metric_name!r}")
        goals[metric_name] = metric.goal_parser(cells[3])

    missing = [metric.name for metric in METRICS if metric.name not in goals]
    if missing:
        fail(f"summary table is missing goal rows for: {', '.join(missing)}")
    return goals


def metric_status(metric: MetricDef, current_value: float, goal: float) -> str:
    if metric.comparator == "eq":
        return "✅" if current_value == goal else "❌"
    if metric.comparator == "min":
        return "✅" if current_value <= goal else "❌"
    if metric.comparator == "max":
        return "✅" if current_value >= goal else "❌"
    raise ValueError(f"unknown comparator {metric.comparator}")


def best_value(metric: MetricDef, entries: list[Entry], goal: float) -> float:
    values = [metric.accessor(entry) for entry in entries]
    if metric.comparator == "eq":
        return min(values, key=lambda value: abs(value - goal))
    if metric.comparator == "min":
        return min(values)
    if metric.comparator == "max":
        return max(values)
    raise ValueError(f"unknown comparator {metric.comparator}")


def render_summary(entries: list[Entry], goals: dict[str, float]) -> list[str]:
    current = entries[-1]
    lines = [
        "## Summary",
        "",
        "| Metric | Current | Best | Goal | Status |",
        "|--------|---------|------|------|--------|",
    ]
    for metric in METRICS:
        goal = goals[metric.name]
        current_value = metric.accessor(current)
        best = best_value(metric, entries, goal)
        status = metric_status(metric, current_value, goal)
        lines.append(
            "| {name} | {current} | {best} | {goal} | {status} |".format(
                name=metric.name,
                current=metric.formatter(current_value),
                best=metric.formatter(best),
                goal=metric.formatter(goal),
                status=status,
            )
        )
    return lines


def render_entry(entry: Entry) -> str:
    viewport = f"`{entry.viewport_width}x{entry.viewport_height}`"
    frame = f"`{entry.frame_width}x{entry.frame_height}`"
    fps = f"`{entry.fps:.1f} fps`"
    frame_pacing = "`—`" if entry.frame_pacing_cv is None else f"`{entry.frame_pacing_cv:.3f}`"
    pipeline = (
        f"`{int(round(entry.pipeline_median_ms))}/"
        f"{int(round(entry.pipeline_p95_ms))}/"
        f"{int(round(entry.pipeline_avg_ms))} ms`"
    )
    g2g = (
        f"`{int(round(entry.g2g_median_ms))}/"
        f"{int(round(entry.g2g_p95_ms))}/"
        f"{int(round(entry.g2g_avg_ms))} ms`"
    )
    if entry.heavy_load_fps is None:
        heavy = "`—`"
    else:
        heavy = (
            f"`{entry.heavy_load_fps:.1f} fps, "
            f"{int(round(entry.heavy_load_pipeline_median_ms or 0))}/"
            f"{int(round(entry.heavy_load_pipeline_p95_ms or 0))} ms`"
        )
    security = f"`{entry.security_rejection}`"
    overall = f"`{entry.overall_passed}/{entry.overall_total}`"
    note_cell = entry.notes
    return (
        f"| {entry.date} | {entry.time} | `{entry.commit_id}` | {viewport} | {frame} | {fps} | "
        f"{frame_pacing} | {pipeline} | {g2g} | {heavy} | {security} | {overall} | {note_cell} |"
    )


def render_changelog(entries: list[Entry]) -> list[str]:
    lines = [
        "## Changelog",
        "",
        "| Date | Time | Commit ID | Viewport | Delivered frame | FPS | Frame pacing | Pipeline latency | Glass-to-glass latency | Heavy load | Security | Overall | Notes |",
        "|------|------|-----------|----------|-----------------|-----|--------------|------------------|------------------------|------------|----------|---------|-------|",
    ]
    lines.extend(render_entry(entry) for entry in entries)
    return lines


def render_file(entries: list[Entry], goals: dict[str, float]) -> str:
    lines = [
        "# Metrics",
        "",
        "This file is machine-managed except for the Goal column in the Summary table.",
        "You may edit Goal values there, but do not edit computed cells or changelog rows by hand.",
        "Use `scripts/update_metrics.py` to add a new metrics entry.",
        "",
        "Rules:",
        "- A new metrics entry requires a unique commit ID.",
        "- The commit ID must already exist in git before the entry is added.",
        "- The changelog is append-only.",
        "- Goal values are read from the Summary table and preserved on rewrite.",
        "- Notes must stay single-line and short enough to keep table rows readable.",
        "",
    ]
    lines.extend(render_summary(entries, goals))
    lines.append("")
    lines.extend(render_changelog(entries))
    lines.append("")
    return "\n".join(lines)


def build_entry_from_args(args: argparse.Namespace) -> Entry:
    commit_id = canonical_commit_id(args.commit_id)
    viewport_width, viewport_height = parse_resolution(args.viewport_resolution)
    frame_width, frame_height = parse_resolution(args.frame_resolution)
    overall_passed, overall_total = parse_overall(args.overall)
    now = datetime.now().astimezone()
    date = args.date or now.strftime("%Y-%m-%d")
    time = args.time or now.strftime("%H:%M:%S %Z")

    return Entry(
        date=date,
        time=time,
        commit_id=commit_id,
        viewport_width=viewport_width,
        viewport_height=viewport_height,
        frame_width=frame_width,
        frame_height=frame_height,
        fps=args.fps,
        frame_pacing_cv=args.frame_pacing_cv,
        pipeline_median_ms=args.pipeline_median_ms,
        pipeline_p95_ms=args.pipeline_p95_ms,
        pipeline_avg_ms=args.pipeline_avg_ms,
        g2g_median_ms=args.g2g_median_ms,
        g2g_p95_ms=args.g2g_p95_ms,
        g2g_avg_ms=args.g2g_avg_ms,
        heavy_load_fps=args.heavy_load_fps,
        heavy_load_pipeline_median_ms=args.heavy_load_pipeline_median_ms,
        heavy_load_pipeline_p95_ms=args.heavy_load_pipeline_p95_ms,
        security_rejection=args.security_rejection,
        overall_passed=overall_passed,
        overall_total=overall_total,
        notes=sanitize_notes(args.notes),
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Update .planning/METRICS.md")
    parser.add_argument(
        "--metrics-path",
        default=str(DEFAULT_METRICS_PATH),
        help="path to the metrics markdown file",
    )
    parser.add_argument("--rewrite-only", action="store_true", help="rewrite the file from existing changelog entries only")
    parser.add_argument("--date", help="row date in YYYY-MM-DD")
    parser.add_argument("--time", help="row time string, for example '15:46:35 EDT'")
    parser.add_argument("--commit-id", help="git commit ID for this metrics row")
    parser.add_argument("--viewport-resolution", help="requested viewport resolution as WIDTHxHEIGHT")
    parser.add_argument("--frame-resolution", help="delivered frame resolution as WIDTHxHEIGHT")
    parser.add_argument("--fps", type=float, help="FPS value")
    parser.add_argument("--frame-pacing-cv", type=float, help="frame pacing coefficient of variation")
    parser.add_argument("--pipeline-median-ms", type=float, help="pipeline latency median in ms")
    parser.add_argument("--pipeline-p95-ms", type=float, help="pipeline latency p95 in ms")
    parser.add_argument("--pipeline-avg-ms", type=float, help="pipeline latency average in ms")
    parser.add_argument("--g2g-median-ms", type=float, help="glass-to-glass latency median in ms")
    parser.add_argument("--g2g-p95-ms", type=float, help="glass-to-glass latency p95 in ms")
    parser.add_argument("--g2g-avg-ms", type=float, help="glass-to-glass latency average in ms")
    parser.add_argument("--heavy-load-fps", type=float, help="heavy-load FPS")
    parser.add_argument("--heavy-load-pipeline-median-ms", type=float, help="heavy-load pipeline median in ms")
    parser.add_argument("--heavy-load-pipeline-p95-ms", type=float, help="heavy-load pipeline p95 in ms")
    parser.add_argument("--security-rejection", type=int, choices=[0, 1], help="1 if unauthenticated clients were rejected, else 0")
    parser.add_argument("--overall", help="overall result as PASSED/TOTAL")
    parser.add_argument("--notes", help="optional one-line note, max 120 chars")
    return parser


def require_fields(args: argparse.Namespace) -> None:
    required = [
        "commit_id",
        "viewport_resolution",
        "frame_resolution",
        "fps",
        "frame_pacing_cv",
        "pipeline_median_ms",
        "pipeline_p95_ms",
        "pipeline_avg_ms",
        "g2g_median_ms",
        "g2g_p95_ms",
        "g2g_avg_ms",
        "heavy_load_fps",
        "heavy_load_pipeline_median_ms",
        "heavy_load_pipeline_p95_ms",
        "security_rejection",
        "overall",
    ]
    missing = [name for name in required if getattr(args, name) is None]
    if missing:
        fail(f"missing required arguments: {', '.join('--' + name.replace('_', '-') for name in missing)}")


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    metrics_path = Path(args.metrics_path).resolve()
    existing_text = metrics_path.read_text()
    goals = parse_summary_goals(existing_text)
    existing_entries = parse_changelog_entries(existing_text)
    if not existing_entries:
        fail("METRICS.md must contain at least one changelog row before using this script")

    if args.rewrite_only:
        metrics_path.write_text(render_file(existing_entries, goals))
        return

    require_fields(args)
    new_entry = build_entry_from_args(args)
    existing_commits = {entry.commit_id for entry in existing_entries}
    if new_entry.commit_id in existing_commits:
        fail(f"commit ID {new_entry.commit_id} already exists in the changelog")

    updated_entries = [*existing_entries, new_entry]
    metrics_path.write_text(render_file(updated_entries, goals))


if __name__ == "__main__":
    main()
