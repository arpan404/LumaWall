#!/usr/bin/env python3
"""Compare two benchmark runs produced by Tools/Benchmarks/run.sh.

Usage: Tools/Benchmarks/compare.py before after
Reads Tools/Benchmarks/results/<label>-{core,poster,bmp}.json.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "results"


def load(label: str) -> dict:
    out = {}
    for part in ("core", "poster", "bmp"):
        path = ROOT / f"{label}-{part}.json"
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        if isinstance(data, list):
            for item in data:
                out[item["name"]] = item
        else:
            out[data["name"]] = data
    return out


def metric(item: dict) -> tuple[str, float] | None:
    for key, unit in (("coldMS", "ms"), ("warmMS", "ms"), ("perUnitNS", "ns")):
        value = item.get(key)
        if isinstance(value, (int, float)) and value:
            return key, value
    return None


def fmt(value: float, unit: str) -> str:
    if unit == "ns":
        return f"{value:,.1f} ns"
    if value >= 1:
        return f"{value:,.2f} ms"
    return f"{value * 1000:,.1f} µs"


def delta(before: float, after: float) -> str:
    if before <= 0:
        return "n/a"
    change = (after - before) / before * 100
    if abs(change) < 0.05:
        return "0%"
    return f"{change:+.1f}%"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    before, after = load(sys.argv[1]), load(sys.argv[2])
    names = list(before) + [name for name in after if name not in before]
    print(f"| benchmark | {sys.argv[1]} | {sys.argv[2]} | change |")
    print("|---|---:|---:|---:|")
    for name in names:
        b, a = before.get(name), after.get(name)
        if not b or not a:
            print(f"| {name} | {'present' if b else '—'} | {'present' if a else '—'} | |")
            continue
        if name == "poster.coldLoad":
            pixels = f"{b.get('pixelsWide')}x{b.get('pixelsHigh')} -> {a.get('pixelsWide')}x{a.get('pixelsHigh')}"
            print(f"| poster.load | {fmt(b['coldMS'], 'ms')} | {fmt(a['coldMS'], 'ms')} | {delta(b['coldMS'], a['coldMS'])} |")
            print(f"| poster.firstDraw ({pixels}) | {fmt(b['warmMS'], 'ms')} | {fmt(a['warmMS'], 'ms')} | {delta(b['warmMS'], a['warmMS'])} |")
            continue
        if name == "library.diskUsage":
            print(f"| library.diskUsage load | {fmt(b['coldMS'], 'ms')} | {fmt(a['coldMS'], 'ms')} | {delta(b['coldMS'], a['coldMS'])} |")
            print(f"| library.diskUsage cached | {fmt(b['warmMS'], 'ms')} | {fmt(a['warmMS'], 'ms')} | {delta(b['warmMS'], a['warmMS'])} |")
            continue
        mb, ma = metric(b), metric(a)
        if not mb or not ma:
            print(f"| {name} | | | |")
            continue
        key, bv = mb
        _, av = ma
        unit = "ns" if key == "perUnitNS" else "ms"
        note = []
        if name == "bmp.encode4K":
            note.append("checksum ok" if b.get("checksum") == a.get("checksum") else "CHECKSUM DIFFERS")
        if b.get("bytes") and a.get("bytes") and b["bytes"] != a["bytes"]:
            note.append(f"{b['bytes']:,} -> {a['bytes']:,} bytes")
        if name in {"policy.windowList", "power.current", "theme.accessibilityRead", "variant.fileExists"}:
            note.append("reference, unchanged call")
        suffix = f" ({'; '.join(note)})" if note else ""
        if key == "coldMS":
            suffix = " load" + suffix
        print(f"| {name}{suffix} | {fmt(bv, unit)} | {fmt(av, unit)} | {delta(bv, av)} |")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
