#!/usr/bin/env python3
"""Aggregate xdist benchmark TSVs into per-config stats + speedup table.

Reads results/*.tsv (schema: arm config n_workers run pytest_s wall_s passed
failed result). Uses only PASS rows. Prints median/min/max/mean of wall_s and
pytest_s per (arm, config), speedup vs each arm's serial baseline, and the best
mean config overall.
"""
import csv
import glob
import os
import statistics as st
from collections import defaultdict

RESULTS = os.path.join(os.path.dirname(__file__), "results")


def load():
    rows = []
    for f in sorted(glob.glob(os.path.join(RESULTS, "*.tsv"))):
        with open(f) as fh:
            for r in csv.DictReader(fh, delimiter="\t"):
                if not r.get("arm"):
                    continue
                rows.append(r)
    return rows


def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def main():
    rows = load()
    # group by (arm, config) keeping n_workers
    groups = defaultdict(list)
    nworkers = {}
    for r in rows:
        if r["result"] != "PASS":
            continue
        w = fnum(r["wall_s"])
        p = fnum(r["pytest_s"])
        if w is None:
            continue
        key = (r["arm"], r["config"])
        groups[key].append((w, p))
        nworkers[key] = int(r["n_workers"])

    # stats
    stats = {}
    for key, vals in groups.items():
        walls = [v[0] for v in vals]
        pys = [v[1] for v in vals if v[1] is not None]
        stats[key] = {
            "n": len(walls),
            "wall_med": st.median(walls),
            "wall_min": min(walls),
            "wall_max": max(walls),
            "wall_mean": st.mean(walls),
            "py_med": st.median(pys) if pys else None,
            "nworkers": nworkers[key],
        }

    arms = sorted({k[0] for k in stats})
    print("=" * 92)
    print("PER-CONFIG STATS (wall seconds, PASS runs only)")
    print("=" * 92)
    hdr = f"{'arm':<14}{'config':<10}{'N':>3}{'runs':>6}{'median':>9}{'min':>8}{'max':>8}{'mean':>8}{'pytest_med':>12}"
    for arm in arms:
        print(f"\n--- {arm} ---")
        print(hdr)
        keys = sorted([k for k in stats if k[0] == arm], key=lambda k: stats[k]["nworkers"])
        # serial baseline = config with nworkers 0
        base = next((stats[k]["wall_med"] for k in keys if stats[k]["nworkers"] == 0), None)
        for k in keys:
            s = stats[k]
            sp = f"  speedup x{base / s['wall_med']:.2f}" if base else ""
            pym = f"{s['py_med']:.1f}" if s["py_med"] is not None else "NA"
            print(f"{k[0]:<14}{k[1]:<10}{s['nworkers']:>3}{s['n']:>6}"
                  f"{s['wall_med']:>9.1f}{s['wall_min']:>8.1f}{s['wall_max']:>8.1f}"
                  f"{s['wall_mean']:>8.1f}{pym:>12}{sp}")

    # best mean overall
    print("\n" + "=" * 92)
    best = min(stats.items(), key=lambda kv: kv[1]["wall_mean"])
    bk, bs = best
    print(f"BEST MEAN WALL TIME: {bs['wall_mean']:.1f}s  ({bk[0]} / {bk[1]} / n={bs['nworkers']}, "
          f"median {bs['wall_med']:.1f}s, n={bs['n']} runs)")

    # pairwise: every arm vs the baseline arm, per matching config
    BASE_ARM = "vm8-pgdef"
    cfgs = sorted({k[1] for k in stats}, key=lambda c: next(stats[k]["nworkers"] for k in stats if k[1] == c))
    for arm in arms:
        if arm == BASE_ARM:
            continue
        print(f"\n{BASE_ARM} vs {arm} (matching configs, median wall):")
        for c in cfgs:
            d = stats.get((BASE_ARM, c), {}).get("wall_med")
            t = stats.get((arm, c), {}).get("wall_med")
            if d and t:
                print(f"  {c:<10} {BASE_ARM}={d:6.1f}s  {arm}={t:6.1f}s  delta={d - t:+.1f}s ({(d - t) / d * 100:+.0f}%)")


if __name__ == "__main__":
    main()
