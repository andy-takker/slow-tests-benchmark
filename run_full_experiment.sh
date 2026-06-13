#!/usr/bin/env bash
# Master driver for the part-2 xdist experiment (plan v2).
# Usage:
#   bash run_full_experiment.sh                 # all three arms
#   bash run_full_experiment.sh vm16-pgdef      # only the named arm(s)
# Arms:
#   vm8-pgdef   default VM, Postgres defaults + max_connections=300
#   vm8-pgfast  default VM, PG tuned: fsync/synchronous_commit/full_page_writes
#               off + data on tmpfs
#   vm16-pgdef  VM 14 CPU / 16 GiB, Postgres defaults + max_connections=300
# Docker daemon restarts happen ONLY when the VM size actually needs to change.
# Launch detached under caffeinate (nohup ... & disown) — see launch protocol.
set -uo pipefail
BENCH="$(cd "$(dirname "$0")" && pwd)"
cd "$BENCH"

stamp(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
trap 'stamp "DRIVER EXIT code=$?"' EXIT

# Full curve: serial baseline + 1..14 workers + oversubscription points.
export RUNS=3
export CONFIGS='serial|0|-n 0
n1|1|-n 1 --dist load
n2|2|-n 2 --dist load
n4|4|-n 4 --dist load
n6|6|-n 6 --dist load
n8|8|-n 8 --dist load
n10|10|-n 10 --dist load
n12|12|-n 12 --dist load
n14|14|-n 14 --dist load
n16|16|-n 16 --dist load
n20|20|-n 20 --dist load'

# Switch VM size only if the current one does not match the target.
ensure_vm(){
  local target=$1 cur
  cur=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  case "$target" in
    16)      [ "$cur" -ge 15000000000 ] && { stamp "VM already 16 GiB ($cur)"; return 0; }
             stamp "switch VM -> 16 GiB"; bash docker_vm.sh 16384 ;;
    default) [ "$cur" -gt 0 ] && [ "$cur" -lt 10000000000 ] && { stamp "VM already default ($cur)"; return 0; }
             stamp "switch VM -> default"; bash docker_vm.sh default ;;
  esac
}

run_arm(){
  case "$1" in
    vm8-pgdef)
      ensure_vm default || return 1
      ARM=vm8-pgdef bash xdist_arm.sh ;;
    vm8-pgfast)
      ensure_vm default || return 1
      ARM=vm8-pgfast \
        PG_EXTRA="-c fsync=off -c synchronous_commit=off -c full_page_writes=off" \
        PG_TMPFS=1 \
        bash xdist_arm.sh ;;
    vm16-pgdef)
      ensure_vm 16 || return 1
      ARM=vm16-pgdef bash xdist_arm.sh ;;
    *) stamp "unknown arm: $1"; return 1 ;;
  esac
}

ARMS=("$@")
[ ${#ARMS[@]} -eq 0 ] && ARMS=(vm8-pgdef vm8-pgfast vm16-pgdef)

i=0
for arm in "${ARMS[@]}"; do
  i=$((i+1))
  stamp "=== ARM $i/${#ARMS[@]}: $arm ==="
  run_arm "$arm" || { stamp "ARM $arm ABORTED ($?)"; ensure_vm default; exit 3; }
done

stamp "=== revert VM -> defaults ==="
ensure_vm default || stamp "WARN: VM revert failed — revert manually"

stamp "=== aggregate ==="
python3 aggregate.py | tee "$BENCH/results/aggregate.out"

stamp "=== EXPERIMENT DONE ==="
