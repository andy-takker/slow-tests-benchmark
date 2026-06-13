#!/usr/bin/env bash
# xdist worker-scaling benchmark — one "arm" (VM size × Postgres config).
# Fresh dedicated Postgres+Redis container PER RUN (resets PG state bloat:
# hundreds of CREATE/DROP DATABASE + WAL + autovacuum across the matrix).
#
# v3 (experiment plan v2). Incident-driven design:
#   * NO Docker Desktop restarts in the happy path (suspect in a silent driver
#     death on freshly-updated Docker 29.5.3); reset_daemon() is an EMERGENCY
#     path only (probe failed / daemon gone).
#   * --memory caps on both containers — the 8 GB VM OOM-killed its daemon
#     after ~17 uncapped churn cycles (containers Exited 137).
#   * Real psql/redis probes before every run; a run with passed<EXPECT is
#     retried on fresh infra, then recorded FAIL; arm ABORTS loudly if infra
#     can't be made healthy — never silently record garbage.
#   * set -x trace to results/<ARM>.debug + EXIT trap — a dying run leaves a trail.
#   * A PASS run with wall−pytest > 15 s is recorded SUSPECT (macOS suspend
#     marker: pytest's monotonic clock pauses during sleep, wall does not).
#
# Inputs (env):
#   ARM      label, e.g. vm8-pgdef / vm8-pgfast / vm16-pgdef
#   RUNS     repeats per config (default 3)
#   EXPECT   expected passing test count (default 3414)
#   RETRY    retries for an infra-signature failed run (default 2)
#   PG_EXTRA extra "-c k=v" postgres args (default none)
#   PG_TMPFS 1 = data dir in tmpfs (sets PGDATA explicitly: postgres:18 moved
#            PGDATA to /var/lib/postgresql/18/docker, a tmpfs on the old path
#            silently covers nothing otherwise)
#   CONFIGS  newline-separated "label|nworkers|pytest-args"
# Outputs: results/<ARM>.tsv, .progress (tail -f), .raw, .debug
set -uo pipefail
cd "${PROJECT_DIR:?set PROJECT_DIR to your backend repo}"

ARM="${ARM:?set ARM}"
RUNS="${RUNS:-3}"
EXPECT="${EXPECT:-3477}"
RETRY="${RETRY:-2}"
PG_EXTRA="${PG_EXTRA:-}"
PG_TMPFS="${PG_TMPFS:-0}"
BENCH="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$BENCH/results"
mkdir -p "$OUTDIR"
TSV="$OUTDIR/$ARM.tsv"
PROG="$OUTDIR/$ARM.progress"
RAW="$OUTDIR/$ARM.raw"
DBG="$OUTDIR/$ARM.debug"
: > "$TSV"; : > "$PROG"; : > "$RAW"; : > "$DBG"
printf 'arm\tconfig\tn_workers\trun\tpytest_s\twall_s\tpassed\tfailed\tresult\n' >> "$TSV"

# Full xtrace to the debug file so any silent death leaves a trail.
# macOS ships bash 3.2: no BASH_XTRACEFD / exec {fd} — route stderr (where
# xtrace goes) to the debug file instead. Intentionally-silenced commands
# keep their own >/dev/null 2>&1.
exec 2>>"$DBG"
PS4='+[$(date +%H:%M:%S)] $LINENO: '
set -x

PG=lms-bench-pg; RD=lms-bench-redis
export APP_DATABASE_HOST=127.0.0.1 APP_DATABASE_PORT=5434 APP_DATABASE_USER=lms APP_DATABASE_PASSWORD=lms APP_DATABASE_NAME=lms
export APP_REDIS_DSN=redis://127.0.0.1:6381

log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$PROG"; }
trap 'log "ARM $ARM EXIT code=$? line=$LINENO"' EXIT

# EMERGENCY ONLY: restart the Docker daemon (keeps persisted VM size).
reset_daemon(){
  log "EMERGENCY: restarting Docker daemon…"
  osascript -e 'quit app "Docker Desktop"' >/dev/null 2>&1 || true
  sleep 8
  pkill -f "Docker.app/Contents/MacOS" >/dev/null 2>&1 || true
  sleep 3
  open -a Docker
  local i
  for i in $(seq 1 90); do docker info >/dev/null 2>&1 && { log "daemon up (${i}x2s) mem=$(docker info --format '{{.MemTotal}}')"; return 0; }; sleep 2; done
  log "FATAL: daemon did not return after reset"; return 1
}

# Real connectivity probe (not just pg_isready, which lies about a half-up VM).
probe_infra(){
  docker exec "$PG" psql -U lms -d lms -tAc 'select 1' >/dev/null 2>&1 || return 1
  docker exec "$RD" redis-cli ping 2>/dev/null | grep -q PONG || return 1
  return 0
}

# Create fresh PG+Redis; verify real connectivity; retry; emergency-restart; abort.
fresh_infra(){
  local attempt i
  # tmpfs pages are charged to the container cgroup -> bigger cap for the tmpfs arm
  local pg_mem=3g; [ "$PG_TMPFS" = 1 ] && pg_mem=4g
  local tmpfs_args=()
  if [ "$PG_TMPFS" = 1 ]; then
    tmpfs_args=(--tmpfs /var/lib/postgresql/data:rw,size=2048m -e PGDATA=/var/lib/postgresql/data)
  fi
  for attempt in 1 2 3; do
    docker info >/dev/null 2>&1 || reset_daemon || { log "ABORT: no daemon"; exit 3; }
    # -v: drop the containers' anonymous volumes (postgres:18 declares
    # VOLUME /var/lib/postgresql — without -v every run leaked a ~2 GB volume;
    # 983 leaked volumes / 142 GB filled the VM disk and killed arm 3).
    docker rm -fv "$PG" "$RD" >/dev/null 2>&1 || true
    docker volume prune -f >/dev/null 2>&1 || true   # safety net: anon-only
    docker run -d --rm --name "$RD" --memory=512m --memory-swap=512m \
      -p 6381:6379 redis:latest redis-server --databases 64 >/dev/null 2>&1
    # shellcheck disable=SC2086 — PG_EXTRA is intentionally word-split;
    # ${arr[@]+...} guards empty-array expansion under set -u on bash 3.2
    docker run -d --rm --name "$PG" --memory=$pg_mem --memory-swap=$pg_mem \
      -e POSTGRES_USER=lms -e POSTGRES_PASSWORD=lms -e POSTGRES_DB=lms \
      ${tmpfs_args[@]+"${tmpfs_args[@]}"} \
      -p 5434:5432 postgres:latest -c max_connections=300 $PG_EXTRA >/dev/null 2>&1
    for i in $(seq 1 40); do docker exec "$PG" pg_isready -U lms >/dev/null 2>&1 && break; sleep 1; done
    sleep 1
    if probe_infra; then return 0; fi
    log "infra probe failed (attempt $attempt) — recreating"
    reset_daemon || { log "ABORT: daemon dead during fresh_infra"; exit 3; }
  done
  log "ABORT: infra could not be made healthy after 3 attempts"; exit 3
}

# run_one <pytest-args...> -> echoes "pytest_s|wall_s|passed|failed|result"
run_one(){
  set +x   # subshell-local: tracing here would dump full pytest output into .debug
  local t0 t1 out summary secs wall passed failed res gap
  t0=$(date +%s)
  out=$(.venv/bin/pytest ./tests "$@" -p no:randomly --no-cov -q 2>&1)
  t1=$(date +%s); wall=$((t1 - t0))
  summary=$(echo "$out" | grep -E '[0-9]+ (passed|failed|error)' | tail -1)
  secs=$(echo "$summary" | grep -oE 'in [0-9.]+s' | grep -oE '[0-9.]+' | tail -1)
  passed=$(echo "$summary" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | head -1)
  failed=$(echo "$summary" | grep -oE '[0-9]+ (failed|error)' | grep -oE '[0-9]+' | head -1)
  if echo "$summary" | grep -qE 'failed|error'; then res=FAIL; else res=PASS; fi
  # macOS-suspend marker: monotonic pytest clock pauses in sleep, wall does not.
  if [ "$res" = PASS ] && [ -n "${secs:-}" ]; then
    gap=$(python3 -c "print(1 if $wall - $secs > 15 else 0)")
    [ "$gap" = 1 ] && res=SUSPECT
  fi
  echo "### $ARM :: $* :: $summary" >> "$RAW"
  echo "${secs:-NA}|${wall}|${passed:-0}|${failed:-0}|${res}"
}

log "ARM=$ARM RUNS=$RUNS EXPECT=$EXPECT PG_TMPFS=$PG_TMPFS PG_EXTRA='$PG_EXTRA'  host cores=$(sysctl -n hw.ncpu)  docker mem=$(docker info --format '{{.MemTotal}}' 2>&1)"

# CONFIGS: "label|nworkers|args"
# Here-string (not a pipe) so `exit` inside the loop terminates the whole script.
while IFS='|' read -r label nworkers args; do
  [ -z "$label" ] && continue
  for r in $(seq 1 "$RUNS"); do
    attempt=0
    while :; do
      fresh_infra
      line=$(run_one $args)
      secs=${line%%|*}; rest=${line#*|}
      wall=${rest%%|*}; rest=${rest#*|}
      passed=${rest%%|*}; rest=${rest#*|}
      failed=${rest%%|*}; res=${rest##*|}
      # Infra-signature failure: passed far below EXPECT -> retry on fresh infra.
      if [ "$res" = FAIL ] && [ "${passed:-0}" -lt "$EXPECT" ] && [ "$attempt" -lt "$RETRY" ]; then
        attempt=$((attempt+1))
        log "$label (n=$nworkers) run$r: INFRA-FAIL passed=${passed} (<$EXPECT) wall=${wall}s — retry $attempt/$RETRY"
        docker info >/dev/null 2>&1 || reset_daemon || { log "ABORT: daemon dead"; exit 3; }
        sleep 3
        continue
      fi
      break
    done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ARM" "$label" "$nworkers" "$r" "$secs" "$wall" "$passed" "$failed" "$res" >> "$TSV"
    log "$label (n=$nworkers) run$r: pytest=${secs}s wall=${wall}s passed=${passed} failed=${failed} $res"
    sleep 3
  done
  log "--- $label done ---"
done <<< "$CONFIGS"

docker rm -fv "$PG" "$RD" >/dev/null 2>&1 || true
docker volume prune -f >/dev/null 2>&1 || true
log "ARM $ARM DONE"
