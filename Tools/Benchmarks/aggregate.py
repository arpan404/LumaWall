#!/usr/bin/env python3
"""Median of repeated benchmark runs.

Usage: Tools/Benchmarks/aggregate.py before
Reads results/<label>-{a,b,c}-{core,poster,bmp}.json and writes
results/<label>-median-{core,poster,bmp}.json for compare.py.
"""
import glob
import json
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "results"


def load_runs(prefix: str, part: str) -> list:
    files = sorted(glob.glob(str(ROOT / f"{prefix}-[abc]-{part}.json")))
    if not files:
        raise SystemExit(f"no runs for {prefix}-*-{part}.json")
    return [json.loads(Path(path).read_text()) for path in files]


def median(values: list[float]) -> float:
    return statistics.median(values)


def aggregate_core(prefix: str) -> None:
    runs = load_runs(prefix, "core")
    by_name: dict[str, list[dict]] = {}
    for run in runs:
        for item in run:
            by_name.setdefault(item["name"], []).append(item)
    out = []
    for name, items in by_name.items():
        merged = {key: value for key, value in items[0].items() if not isinstance(value, (int, float))}
        for key in ("coldMS", "warmMS", "perUnitNS"):
            values = [item[key] for item in items if isinstance(item.get(key), (int, float))]
            if values:
                merged[key] = median(values)
        if isinstance(items[0].get("bytes"), int):
            merged["bytes"] = items[0]["bytes"]
        merged["name"] = name
        out.append(merged)
    (ROOT / f"{prefix}-median-core.json").write_text(json.dumps(out, indent=2))


def aggregate_single(prefix: str, part: str, numeric: tuple[str, ...]) -> None:
    runs = load_runs(prefix, part)
    merged = {key: value for key, value in runs[0].items() if not isinstance(value, (int, float))}
    for key in numeric:
        values = [run[key] for run in runs if isinstance(run.get(key), (int, float))]
        if values:
            merged[key] = median(values)
    if part == "bmp":
        checksums = {run.get("checksum") for run in runs}
        if len(checksums) != 1:
            raise SystemExit(f"BMP checksum changed across runs: {checksums}")
    for key in ("pixelsWide", "pixelsHigh"):
        if part == "poster" and key in runs[0]:
            merged[key] = runs[0][key]
    (ROOT / f"{prefix}-median-{part}.json").write_text(json.dumps(merged, indent=2))


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    prefix = sys.argv[1]
    aggregate_core(prefix)
    aggregate_single(prefix, "poster", ("coldMS", "warmMS"))
    aggregate_single(prefix, "bmp", ("warmMS",))
    print(f"wrote {prefix}-median-*.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
