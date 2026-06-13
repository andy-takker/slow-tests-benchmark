#!/usr/bin/env bash
# Wait for the currently-running arm-3 driver to finish, archive the dirty-disk
# vm8 results (taken while the anonymous-volume leak was filling the VM disk —
# kept as drift evidence for the report), then rerun arms 1-2 on a clean disk
# with the fixed harness (docker rm -fv + volume prune per run).
set -uo pipefail
BENCH="$(cd "$(dirname "$0")" && pwd)"
cd "$BENCH"
echo "[$(date '+%H:%M:%S')] queue: waiting for current driver to finish…"
while pgrep -f "bash run_full_experiment.sh" >/dev/null; do sleep 20; done
echo "[$(date '+%H:%M:%S')] queue: driver gone, archiving dirty-disk vm8 results"
mkdir -p results/archive-dirty-disk
for f in vm8-pgdef vm8-pgfast; do
  for ext in tsv progress raw debug; do
    cp "results/$f.$ext" "results/archive-dirty-disk/" 2>/dev/null || true
  done
done
echo "[$(date '+%H:%M:%S')] queue: relaunching arms 1-2 on clean disk"
exec bash run_full_experiment.sh vm8-pgdef vm8-pgfast
