#!/usr/bin/env python3
# Charts for the part-2 xdist article. Reads real results/*.tsv + cleanup CSV.
# Run: uv run --with matplotlib python make_charts.py
import csv
import statistics
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator

HERE = Path(__file__).parent
RES = HERE / "results"
IMG = HERE / "images"
IMG.mkdir(exist_ok=True)

plt.rcParams.update(
    {
        "font.size": 12,
        "axes.grid": True,
        "grid.alpha": 0.3,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "figure.dpi": 140,
    }
)
INK = "#1f2a44"
ACCENT = "#d7263d"
BLUE = "#2364aa"
GREEN = "#3a9d23"
GREY = "#9aa0a6"


def medians(arm):
    """config -> median wall seconds (PASS only), ordered by worker count."""
    rows = {}
    with open(RES / f"{arm}.tsv") as fh:
        for r in csv.DictReader(fh, delimiter="\t"):
            if r["result"] != "PASS":
                continue
            rows.setdefault((int(r["n_workers"]), r["config"]), []).append(
                float(r["wall_s"])
            )
    out = sorted((n, cfg, statistics.median(v)) for (n, cfg), v in rows.items())
    return out


def workers_times(arm):
    data = medians(arm)
    ns = [n for n, _, _ in data]
    ts = [t for _, _, t in data]
    return ns, ts


# ---- Chart 1: scaling vs ideal -------------------------------------------
ns, ts = workers_times("vm8-pgdef")
serial = ts[0]  # n=0
# xdist points: skip serial (n=0)
xn = [n for n in ns if n > 0]
xt = [t for n, t in zip(ns, ts) if n > 0]
ideal = [serial / n for n in xn]

fig, ax = plt.subplots(figsize=(9, 5.2))
ax.axhline(serial, ls="--", color=GREY, lw=1.5)
ax.text(2, serial + 2, f"последовательно — {serial:.0f} с", color=GREY, ha="left")
ax.plot(xn, ideal, ls=":", color=GREY, lw=2, label="идеальное масштабирование (T/N)")
ax.plot(xn, xt, "-o", color=ACCENT, lw=2.5, ms=7, label="реально (pytest-xdist)")
# annotate knee + best
ax.annotate(
    "колено: n=8\n×3.2",
    xy=(8, 29),
    xytext=(8.3, 52),
    color=INK,
    arrowprops=dict(arrowstyle="->", color=INK),
)
ax.annotate(
    "лучшее: n=14, 28 с (×3.4)",
    xy=(14, 28),
    xytext=(10.5, 16),
    color=ACCENT,
    arrowprops=dict(arrowstyle="->", color=ACCENT),
)
ax.annotate(
    "10 P-ядер",
    xy=(10, ideal[xn.index(10)]),
    xytext=(11.5, 9),
    color=GREY,
    fontsize=10,
)
ax.set_xlabel("число воркеров (-n)")
ax.set_ylabel("время прогона, с (медиана из 3)")
ax.set_title("pytest-xdist: реальная кривая упирается в потолок ×3.4, а не в ×14")
ax.set_xticks(xn)
ax.set_ylim(0, serial + 8)
ax.legend(frameon=False, loc="upper right")
fig.tight_layout()
fig.savefig(IMG / "scaling_vs_ideal.png")
plt.close(fig)

# ---- Chart 2: three arms overlay (the two myths) -------------------------
fig, ax = plt.subplots(figsize=(9, 5.2))
arms = [
    ("vm8-pgdef", "дефолт VM 8 ГБ + дефолт PG", BLUE, "-o"),
    ("vm16-pgdef", "VM 16 ГиБ + дефолт PG", GREEN, "--s"),
    ("vm8-pgfast", "VM 8 ГБ + PG fsync=off+tmpfs", ACCENT, ":^"),
]
for arm, label, color, style in arms:
    n, t = workers_times(arm)
    n2 = [x for x in n if x > 0]
    t2 = [tt for x, tt in zip(n, t) if x > 0]
    ax.plot(n2, t2, style, color=color, lw=2, ms=6, label=label)
ax.set_xlabel("число воркеров (-n)")
ax.set_ylabel("время прогона, с (медиана из 3)")
ax.set_title("Память VM не влияет, тюнинг PG скорее вредит: три плеча почти совпадают")
ax.set_xticks([n for n in ns if n > 0])
ax.legend(frameon=False, loc="upper right")
ax.set_ylim(0, 75)
fig.tight_layout()
fig.savefig(IMG / "arms_overlay.png")
plt.close(fig)

# ---- Chart 3: cleanup microbench (A5½) -----------------------------------
cb = {}
with open(RES / "cleanup_bench_300.csv") as fh:
    for r in csv.DictReader(fh):
        cb[r["strategy"]] = (
            float(r["median_ms"]),
            float(r["min_ms"]),
            float(r["max_ms"]),
        )
order = ["delete", "truncate", "template"]
labels = ["DELETE\nпо таблицам", "TRUNCATE\n…CASCADE", "DROP+CREATE\nTEMPLATE"]
meds = [cb[k][0] for k in order]
lo = [cb[k][0] - cb[k][1] for k in order]
hi = [cb[k][2] - cb[k][0] for k in order]
colors = [GREEN, BLUE, ACCENT]
fig, ax = plt.subplots(figsize=(8, 5))
bars = ax.bar(labels, meds, yerr=[lo, hi], capsize=6, color=colors, width=0.6)
for b, k in zip(bars, order):
    mult = cb[k][0] / cb["delete"][0]
    ax.text(
        b.get_x() + b.get_width() / 2,
        cb[k][2] + 1.5,
        f"{cb[k][0]:.1f} мс\n×{mult:.1f}",
        ha="center",
        color=INK,
        fontsize=11,
    )
ax.set_ylabel("время на очистку, мс / тест")
ax.set_title(
    "Очистка БД между тестами: DELETE дешевле и стабильнее\n"
    "(медиана, усы — min/max за 300 циклов)",
    fontsize=13,
)
ax.set_ylim(0, max(cb[k][2] for k in order) + 12)
fig.tight_layout()
fig.savefig(IMG / "cleanup_bench.png")
plt.close(fig)

# ---- Chart 4: CI before/after (runner 2, current suite) ------------------
fig, ax = plt.subplots(figsize=(7, 4.6))
ci_labels = ["до xdist\n(serial, n=13)", "после xdist\n(-n auto)"]
ci_vals = [449, 166]
bars = ax.bar(ci_labels, ci_vals, color=[GREY, GREEN], width=0.55)
ax.errorbar(0, 449, yerr=[[39], [31]], fmt="none", ecolor=INK, capsize=6)  # 410-480
ax.text(0, 505, "449 с ≈ 7.5 мин", ha="center", color=INK)
ax.text(1, 174, "166 с ≈ 2.8 мин", ha="center", color=INK)
ax.text(0.5, 300, "×2.7", ha="center", color=ACCENT, fontsize=22, fontweight="bold")
ax.set_ylabel("стадия test в CI, с")
ax.set_title("Стадия test в CI: serial vs -n auto\n(тот же раннер, текущий сьют)", fontsize=13)
ax.set_ylim(0, 560)
fig.tight_layout()
fig.savefig(IMG / "ci_before_after.png")
plt.close(fig)

print("wrote:")
for p in sorted(IMG.glob("*.png")):
    print(" ", p, f"{p.stat().st_size//1024} KB")
