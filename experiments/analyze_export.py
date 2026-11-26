#!/usr/bin/env python3
"""Descriptive and inferential summary for an ExperimentExporter folder.

Usage:
    python experiments/analyze_export.py user://exports/...   # or the real path
    python experiments/analyze_export.py path/to/experiment --out analysis.md

Only the standard library is required for the descriptive tables. If pandas and
scipy are installed, the script also runs a Friedman test per scenario and
pairwise Wilcoxon signed-rank tests with Holm correction.
"""

from __future__ import annotations

import argparse
import csv
import math
import statistics
from collections import Counter, defaultdict
from pathlib import Path


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def as_float(value: str | None) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, math.ceil(len(ordered) * fraction) - 1))
    return ordered[index]


def describe(values: list[float]) -> dict[str, float]:
    finite = [value for value in values if math.isfinite(value)]
    if not finite:
        return {"n": 0, "mean": float("nan"), "sd": float("nan"), "median": float("nan"), "p95": float("nan"), "cv": float("nan")}
    mean = statistics.fmean(finite)
    sd = statistics.pstdev(finite) if len(finite) < 2 else statistics.stdev(finite)
    return {
        "n": len(finite),
        "mean": mean,
        "sd": sd,
        "median": statistics.median(finite),
        "p95": percentile(finite, 0.95),
        "cv": (sd / mean) if mean else float("nan"),
    }


def descriptive(rows: list[dict[str, str]]) -> str:
    grouped: dict[tuple[str, str], list[float]] = defaultdict(list)

    for row in rows:
        value = as_float(row.get("total_evacuation_time_s"))
        if value is not None:
            grouped[(row.get("scenario", ""), row.get("condition", ""))].append(value)

    lines = [
        "# Descriptive summary",
        "",
        "| Scenario | Condition | n | Mean total (s) | SD | Median | P95 | CV |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ]

    for (scenario, condition), values in sorted(grouped.items()):
        stats = describe(values)
        lines.append(
            "| {scenario} | {condition} | {n} | {mean:.2f} | {sd:.2f} | "
            "{median:.2f} | {p95:.2f} | {cv:.3f} |".format(
                scenario=scenario, condition=condition, **stats
            )
        )

    lines.append("")
    lines.append("## Predicted vs measured")
    lines.append("")
    errors = [as_float(row.get("prediction_error_s")) for row in rows]
    errors = [value for value in errors if value is not None]
    if errors:
        mae = statistics.fmean(abs(value) for value in errors)
        rmse = math.sqrt(statistics.fmean(value * value for value in errors))
        lines.append(f"- Errors: {len(errors)}")
        lines.append(f"- Bias (predicted - measured): {statistics.fmean(errors):.3f} s")
        lines.append(f"- MAE: {mae:.3f} s")
        lines.append(f"- RMSE: {rmse:.3f} s")
    else:
        lines.append("- No prediction-error rows (no optimizer estimate recorded).")

    counts = Counter(row.get("condition", "") for row in rows)
    lines.append("")
    lines.append("## Run counts")
    lines.append("")
    for condition, count in sorted(counts.items()):
        lines.append(f"- {condition}: {count}")

    return "\n".join(lines) + "\n"


def inferential(rows: list[dict[str, str]]) -> str:
    try:
        import pandas as pd
        from scipy.stats import friedmanchisquare, wilcoxon
    except Exception as exc:  # pragma: no cover - optional dependency
        return f"\n## Inferential tests\n\nSkipped: pandas/scipy unavailable ({exc}).\n"

    frame = pd.DataFrame(rows)
    frame["total_evacuation_time_s"] = pd.to_numeric(
        frame["total_evacuation_time_s"], errors="coerce"
    )
    frame = frame.dropna(subset=["total_evacuation_time_s"])
    lines = ["\n## Inferential tests", ""]

    if frame.empty:
        return "\n## Inferential tests\n\nNo finite rows.\n"

    for scenario, group in frame.groupby("scenario"):
        wide = group.pivot_table(
            index=["seed", "repeat_index"], columns="condition",
            values="total_evacuation_time_s", aggfunc="mean",
        ).dropna(axis=0, how="any")
        conditions = list(wide.columns)

        if len(conditions) < 3 or len(wide) < 2:
            lines.append(f"### {scenario}: not enough complete blocks (n={len(wide)}).")
            continue

        samples = [wide[condition].to_numpy() for condition in conditions]
        statistic, p_value = friedmanchisquare(*samples)
        lines.append(
            f"### {scenario}\n\nFriedman chi2={statistic:.3f}, p={p_value:.4g}, "
            f"blocks={len(wide)}, conditions={len(conditions)}."
        )

        # Pairwise Wilcoxon with Holm correction. This is descriptive post-hoc;
        # keep it out of the primary claim unless the adviser agrees.
        pairs = []
        for left_index, left in enumerate(conditions):
            for right in conditions[left_index + 1:]:
                if (wide[left] == wide[right]).all():
                    continue
                result = wilcoxon(wide[left], wide[right], zero_method="wilcox")
                pairs.append((left, right, float(result.pvalue)))

        if not pairs:
            continue

        ordered = sorted(pairs, key=lambda item: item[2])
        adjusted = []
        running = 0.0
        for index, (left, right, p_value_pair) in enumerate(ordered):
            factor = len(ordered) - index
            corrected = min(1.0, p_value_pair * factor)
            running = max(running, corrected)
            adjusted.append((left, right, p_value_pair, running))

        lines.append("")
        lines.append("| Pair | raw p | Holm p |")
        lines.append("|---|---:|---:|")
        for left, right, raw, corrected in adjusted:
            lines.append(f"| {left} vs {right} | {raw:.4g} | {corrected:.4g} |")

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export_dir", type=Path)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    runs_path = args.export_dir / "runs.csv"
    if not runs_path.exists():
        raise SystemExit(f"runs.csv not found in {args.export_dir}")

    rows = read_rows(runs_path)
    text = descriptive(rows) + inferential(rows)
    out_path = args.out or (args.export_dir / "analysis_summary.md")
    out_path.write_text(text, encoding="utf-8")
    print(text)
    print(f"\nWrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
