#!/usr/bin/env python3
"""
visualize_raft_metrics.py
=========================
Fetches Raft metrics from the demo app at http://localhost:9090
and produces a full suite of visualizations:

  1. Node state gauge (Leader / Follower / Candidate)
  2. Log index timeline  (commit, applied, last_log over time)
  3. FSM pending queue bar
  4. Go runtime panel   (goroutines, heap MB, GC cycles)
  5. Raft term history  (term over time)
  6. Log lag             (last_log_index − applied_index over time)
  7. Live rolling dashboard (all panels, auto-refresh)

Usage
-----
  # One-shot snapshot (saves PNG):
  python visualize_raft_metrics.py --mode snapshot

  # Live rolling dashboard (Ctrl-C to stop):
  python visualize_raft_metrics.py --mode live

  # Use a different endpoint:
  python visualize_raft_metrics.py --url http://localhost:9090

Requirements
------------
  pip install requests matplotlib numpy
"""

import argparse
import time
import sys
from collections import deque
from datetime import datetime

import requests
import matplotlib
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import matplotlib.patches as mpatches
import numpy as np

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DEFAULT_URL      = "http://localhost:9090"
STATS_ENDPOINT   = "/stats"          # returns "key = value\n" lines
HEALTH_ENDPOINT  = "/health"
POLL_INTERVAL    = 1.0               # seconds between polls (live mode)
HISTORY_LEN      = 60               # data points kept in rolling window
SNAPSHOT_OUT     = "raft_metrics_snapshot.png"

STATE_COLORS = {
    "Leader":    "#2d7a3a",
    "Follower":  "#185fa5",
    "Candidate": "#b06000",
    "Shutdown":  "#b02020",
}
STATE_ORDER = ["Leader", "Candidate", "Follower", "Shutdown"]

# ---------------------------------------------------------------------------
# Data fetching
# ---------------------------------------------------------------------------

def fetch_stats(base_url: str) -> dict:
    """
    GET /stats  →  dict[str, str]
    Returns an empty dict on any error so the caller can keep running.
    """
    try:
        r = requests.get(base_url + STATS_ENDPOINT, timeout=2)
        r.raise_for_status()
        result = {}
        for line in r.text.splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                result[k.strip()] = v.strip()
        return result
    except Exception as e:
        print(f"[WARN] fetch_stats failed: {e}", file=sys.stderr)
        return {}


def safe_int(d: dict, key: str, default: int = 0) -> int:
    try:
        return int(d.get(key, default))
    except ValueError:
        return default


# ---------------------------------------------------------------------------
# Individual plot helpers
# ---------------------------------------------------------------------------

def plot_state_gauge(ax, state: str):
    """Big coloured circle showing current node state."""
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")
    color = STATE_COLORS.get(state, "#888888")
    circle = plt.Circle((0.5, 0.52), 0.35, color=color, zorder=2)
    ax.add_patch(circle)
    ax.text(0.5, 0.52, state, ha="center", va="center",
            fontsize=18, fontweight="bold", color="white", zorder=3)
    ax.text(0.5, 0.08, "Node State", ha="center", va="bottom",
            fontsize=11, color="#555")
    # Legend pills
    for i, s in enumerate(STATE_ORDER):
        c = STATE_COLORS[s]
        rect = mpatches.FancyBboxPatch(
            (0.04 + i * 0.24, 0.00), 0.20, 0.07,
            boxstyle="round,pad=0.01", facecolor=c, edgecolor="none", alpha=0.85
        )
        ax.add_patch(rect)
        ax.text(0.04 + i * 0.24 + 0.10, 0.035, s,
                ha="center", va="center", fontsize=7.5, color="white", fontweight="bold")
    ax.set_title("Node State", fontsize=12, fontweight="semibold", pad=6)


def plot_index_timeline(ax, ts, commit_hist, applied_hist, lastlog_hist):
    """Line chart of commit / applied / last_log indices over time."""
    if not ts:
        ax.text(0.5, 0.5, "Waiting for data…", ha="center", va="center", transform=ax.transAxes)
        return
    t = list(ts)
    ax.plot(t, list(commit_hist),  label="commit_index",  color="#2d7a3a", linewidth=2)
    ax.plot(t, list(applied_hist), label="applied_index", color="#185fa5", linewidth=2, linestyle="--")
    ax.plot(t, list(lastlog_hist), label="last_log_index", color="#9b4dca", linewidth=1.5, linestyle=":")
    ax.set_title("Log Indices Over Time", fontsize=12, fontweight="semibold")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Index")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    ax.yaxis.set_major_locator(matplotlib.ticker.MaxNLocator(integer=True))


def plot_fsm_pending(ax, fsm_pending: int):
    """Horizontal bar showing FSM backlog."""
    max_shown = max(fsm_pending, 10)
    color = "#2d7a3a" if fsm_pending == 0 else ("#b06000" if fsm_pending < 5 else "#b02020")
    ax.barh(["FSM\nPending"], [fsm_pending], color=color, height=0.4, zorder=2)
    ax.barh(["FSM\nPending"], [max_shown], color="#eeeeee", height=0.4, zorder=1)
    ax.set_xlim(0, max_shown * 1.15)
    ax.text(fsm_pending + max_shown * 0.02, 0,
            str(fsm_pending), va="center", fontsize=14, fontweight="bold", color=color)
    ax.set_title("FSM Pending Queue", fontsize=12, fontweight="semibold")
    ax.axis("off")
    ax.set_title("FSM Pending Queue", fontsize=12, fontweight="semibold", pad=6)


def plot_runtime(ax, goroutines: int, heap_mb: float, gc_count: int):
    """Grouped bar for Go runtime metrics (normalised)."""
    labels   = ["Goroutines", "Heap (MB)", "GC Cycles"]
    values   = [goroutines, heap_mb, gc_count]
    colors   = ["#185fa5", "#2d7a3a", "#b06000"]
    x = np.arange(len(labels))
    bars = ax.bar(x, values, color=colors, width=0.5, zorder=2)
    for bar, val in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width() / 2,
                bar.get_height() + max(values) * 0.01,
                f"{val:.1f}" if isinstance(val, float) else str(val),
                ha="center", va="bottom", fontsize=10, fontweight="bold")
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=10)
    ax.set_title("Go Runtime", fontsize=12, fontweight="semibold")
    ax.set_ylabel("Value")
    ax.grid(axis="y", alpha=0.3)
    ax.set_ylim(0, max(values) * 1.25 if max(values) > 0 else 10)


def plot_term_history(ax, ts, term_hist):
    """Step chart of Raft term over time."""
    if not ts:
        ax.text(0.5, 0.5, "Waiting for data…", ha="center", va="center", transform=ax.transAxes)
        return
    ax.step(list(ts), list(term_hist), where="post", color="#9b4dca", linewidth=2)
    ax.fill_between(list(ts), list(term_hist), step="post", alpha=0.15, color="#9b4dca")
    ax.set_title("Election Term History", fontsize=12, fontweight="semibold")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Term")
    ax.yaxis.set_major_locator(matplotlib.ticker.MaxNLocator(integer=True))
    ax.grid(True, alpha=0.3)


def plot_log_lag(ax, ts, lag_hist):
    """Area chart of (last_log_index − applied_index) = replication lag."""
    if not ts:
        ax.text(0.5, 0.5, "Waiting for data…", ha="center", va="center", transform=ax.transAxes)
        return
    t = list(ts)
    lag = list(lag_hist)
    ax.fill_between(t, lag, alpha=0.4, color="#b06000")
    ax.plot(t, lag, color="#b06000", linewidth=2)
    ax.set_title("Log Lag  (last_log − applied)", fontsize=12, fontweight="semibold")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Entries")
    ax.yaxis.set_major_locator(matplotlib.ticker.MaxNLocator(integer=True))
    ax.set_ylim(bottom=0)
    ax.grid(True, alpha=0.3)


# ---------------------------------------------------------------------------
# Snapshot mode
# ---------------------------------------------------------------------------

def snapshot(base_url: str):
    print(f"[INFO] Fetching metrics from {base_url} …")
    stats = fetch_stats(base_url)
    if not stats:
        print("[ERROR] Could not fetch any stats. Is the demo running?")
        sys.exit(1)

    state       = stats.get("state", "Unknown")
    term        = safe_int(stats, "term")
    commit      = safe_int(stats, "commit_index")
    applied     = safe_int(stats, "applied_index")
    last_log    = safe_int(stats, "last_log_index")
    fsm_pending = safe_int(stats, "fsm_pending")

    # Fake single-point histories so the timeline helpers work
    ts           = deque([0], maxlen=1)
    commit_h     = deque([commit],   maxlen=1)
    applied_h    = deque([applied],  maxlen=1)
    lastlog_h    = deque([last_log], maxlen=1)
    term_h       = deque([term],     maxlen=1)
    lag_h        = deque([last_log - applied], maxlen=1)

    fig = plt.figure(figsize=(16, 10))
    fig.patch.set_facecolor("#f7f7f9")
    fig.suptitle(
        f"Raft Metrics Snapshot  ·  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        fontsize=14, fontweight="bold", y=0.98
    )
    gs = gridspec.GridSpec(2, 3, figure=fig, hspace=0.45, wspace=0.35)

    ax_state   = fig.add_subplot(gs[0, 0])
    ax_indices = fig.add_subplot(gs[0, 1])
    ax_fsm     = fig.add_subplot(gs[0, 2])
    ax_runtime = fig.add_subplot(gs[1, 0])
    ax_term    = fig.add_subplot(gs[1, 1])
    ax_lag     = fig.add_subplot(gs[1, 2])

    for ax in [ax_state, ax_indices, ax_fsm, ax_runtime, ax_term, ax_lag]:
        ax.set_facecolor("#ffffff")
        for spine in ax.spines.values():
            spine.set_edgecolor("#dddddd")

    plot_state_gauge(ax_state, state)
    plot_index_timeline(ax_indices, ts, commit_h, applied_h, lastlog_h)
    plot_fsm_pending(ax_fsm, fsm_pending)
    plot_runtime(ax_runtime, goroutines=0, heap_mb=0.0, gc_count=0)  # runtime not in /stats
    plot_term_history(ax_term, ts, term_h)
    plot_log_lag(ax_lag, ts, lag_h)

    # Stats table annotation
    fig.text(0.01, 0.01,
             "  ".join(f"{k}={v}" for k, v in sorted(stats.items())),
             fontsize=7, color="#aaa", va="bottom")

    plt.savefig(SNAPSHOT_OUT, dpi=150, bbox_inches="tight", facecolor=fig.get_facecolor())
    print(f"[INFO] Saved → {SNAPSHOT_OUT}")
    plt.show()


# ---------------------------------------------------------------------------
# Live rolling dashboard
# ---------------------------------------------------------------------------

def live(base_url: str):
    print(f"[INFO] Starting live dashboard — polling {base_url} every {POLL_INTERVAL}s")
    print("       Press Ctrl-C to stop.\n")

    matplotlib.use("TkAgg" if "Tk" in matplotlib.rcsetup.all_backends else "Qt5Agg")
    plt.ion()

    fig = plt.figure(figsize=(16, 10))
    fig.patch.set_facecolor("#f7f7f9")
    gs = gridspec.GridSpec(2, 3, figure=fig, hspace=0.45, wspace=0.35)

    axes = {
        "state":   fig.add_subplot(gs[0, 0]),
        "indices": fig.add_subplot(gs[0, 1]),
        "fsm":     fig.add_subplot(gs[0, 2]),
        "runtime": fig.add_subplot(gs[1, 0]),
        "term":    fig.add_subplot(gs[1, 1]),
        "lag":     fig.add_subplot(gs[1, 2]),
    }
    for ax in axes.values():
        ax.set_facecolor("#ffffff")
        for spine in ax.spines.values():
            spine.set_edgecolor("#dddddd")

    # Rolling histories
    N = HISTORY_LEN
    ts_hist      = deque(maxlen=N)
    commit_hist  = deque(maxlen=N)
    applied_hist = deque(maxlen=N)
    lastlog_hist = deque(maxlen=N)
    term_hist    = deque(maxlen=N)
    lag_hist     = deque(maxlen=N)
    goroutine_hist = deque(maxlen=N)
    heap_hist    = deque(maxlen=N)
    gc_hist      = deque(maxlen=N)

    start = time.time()
    frame = 0

    try:
        while True:
            stats = fetch_stats(base_url)
            now   = round(time.time() - start, 1)

            state       = stats.get("state", "Unknown")
            term        = safe_int(stats, "term")
            commit      = safe_int(stats, "commit_index")
            applied     = safe_int(stats, "applied_index")
            last_log    = safe_int(stats, "last_log_index")
            fsm_pending = safe_int(stats, "fsm_pending")

            ts_hist.append(now)
            commit_hist.append(commit)
            applied_hist.append(applied)
            lastlog_hist.append(last_log)
            term_hist.append(term)
            lag_hist.append(max(0, last_log - applied))

            for ax in axes.values():
                ax.cla()
                ax.set_facecolor("#ffffff")
                for spine in ax.spines.values():
                    spine.set_edgecolor("#dddddd")

            plot_state_gauge(axes["state"], state)
            plot_index_timeline(axes["indices"], ts_hist, commit_hist, applied_hist, lastlog_hist)
            plot_fsm_pending(axes["fsm"], fsm_pending)
            plot_runtime(axes["runtime"],
                         goroutines=len(goroutine_hist),   # placeholder; /stats has no goroutine key
                         heap_mb=0.0,
                         gc_count=safe_int(stats, "last_snapshot_index"))
            plot_term_history(axes["term"], ts_hist, term_hist)
            plot_log_lag(axes["lag"], ts_hist, lag_hist)

            fig.suptitle(
                f"Raft Live Dashboard  ·  {datetime.now().strftime('%H:%M:%S')}  "
                f"·  frame {frame}",
                fontsize=13, fontweight="bold"
            )

            plt.pause(POLL_INTERVAL)
            frame += 1

    except KeyboardInterrupt:
        print("\n[INFO] Stopped.")
    finally:
        plt.ioff()
        plt.show()


# ---------------------------------------------------------------------------
# Standalone simulation (no running server needed)
# ---------------------------------------------------------------------------

def simulate():
    """
    Generate a synthetic Raft metrics timeline and plot all 6 panels.
    Useful for testing / demo without a running raft-demo binary.
    """
    print("[INFO] Running in SIMULATE mode (no server required)")

    N    = 60
    ts   = list(range(N))
    term = [1]*20 + [2]*40
    commit  = list(range(0, N))
    applied = [max(0, c - np.random.randint(0, 3)) for c in commit]
    lastlog = [c + np.random.randint(0, 2) for c in commit]
    lag      = [l - a for l, a in zip(lastlog, applied)]
    fsm_now  = lag[-1]
    state    = "Leader"

    fig = plt.figure(figsize=(16, 10))
    fig.patch.set_facecolor("#f7f7f9")
    fig.suptitle("Raft Metrics — Simulated Data", fontsize=14, fontweight="bold", y=0.98)
    gs = gridspec.GridSpec(2, 3, figure=fig, hspace=0.45, wspace=0.35)

    panels = [
        fig.add_subplot(gs[0, 0]),
        fig.add_subplot(gs[0, 1]),
        fig.add_subplot(gs[0, 2]),
        fig.add_subplot(gs[1, 0]),
        fig.add_subplot(gs[1, 1]),
        fig.add_subplot(gs[1, 2]),
    ]
    for ax in panels:
        ax.set_facecolor("#ffffff")
        for spine in ax.spines.values():
            spine.set_edgecolor("#dddddd")

    plot_state_gauge(panels[0], state)
    plot_index_timeline(panels[1],
                        deque(ts, maxlen=N),
                        deque(commit, maxlen=N),
                        deque(applied, maxlen=N),
                        deque(lastlog, maxlen=N))
    plot_fsm_pending(panels[2], fsm_now)
    plot_runtime(panels[3], goroutines=12, heap_mb=8.4, gc_count=3)
    plot_term_history(panels[4], deque(ts, maxlen=N), deque(term, maxlen=N))
    plot_log_lag(panels[5], deque(ts, maxlen=N), deque(lag, maxlen=N))

    out = "raft_metrics_simulated.png"
    plt.savefig(out, dpi=150, bbox_inches="tight", facecolor=fig.get_facecolor())
    print(f"[INFO] Saved → {out}")
    plt.show()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Visualize Raft metrics from the hashicorp/raft demo app.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--mode",
        choices=["snapshot", "live", "simulate"],
        default="simulate",
        help="snapshot = one PNG; live = rolling dashboard; simulate = no server needed (default)",
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_URL,
        help=f"Base URL of the raft-demo server (default: {DEFAULT_URL})",
    )
    args = parser.parse_args()

    if args.mode == "simulate":
        simulate()
    elif args.mode == "snapshot":
        snapshot(args.url)
    elif args.mode == "live":
        live(args.url)


if __name__ == "__main__":
    main()