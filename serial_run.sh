#!/usr/bin/env bash
# Serial baseline via `-n 0` (xdist plugin loaded, zero workers -> worker_id=
# "master", single process). Cannot use `-p no:xdist` because that unloads the
# plugin and removes the worker_id fixture db_config/redis_config depend on.
# Fresh container per run. Appends rows to results/<ARM>.tsv.
set -uo pipefail
cd "${PROJECT_DIR:?set PROJECT_DIR to your backend repo}"
ARM="${ARM:?}"; RUNS="${RUNS:-3}"
OUTDIR="$(cd "$(dirname "$0")" && pwd)/results"
TSV="$OUTDIR/$ARM.tsv"; PROG="$OUTDIR/$ARM.progress"
PG=lms-bench-pg; RD=lms-bench-redis
export APP_DATABASE_HOST=127.0.0.1 APP_DATABASE_PORT=5434 APP_DATABASE_USER=lms APP_DATABASE_PASSWORD=lms APP_DATABASE_NAME=lms
export APP_REDIS_DSN=redis://127.0.0.1:6381
log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$PROG"; }
fresh(){
  docker rm -f "$PG" "$RD" >/dev/null 2>&1 || true
  docker run -d --rm --name "$RD" -p 6381:6379 redis:latest redis-server --databases 64 >/dev/null
  docker run -d --rm --name "$PG" -e POSTGRES_USER=lms -e POSTGRES_PASSWORD=lms -e POSTGRES_DB=lms \
    -p 5434:5432 postgres:latest -c max_connections=300 >/dev/null
  for i in $(seq 1 40); do docker exec "$PG" pg_isready -U lms >/dev/null 2>&1 && break; sleep 1; done
  sleep 1
}
for r in $(seq 1 "$RUNS"); do
  fresh
  t0=$(date +%s)
  out=$(.venv/bin/pytest ./tests -n 0 -p no:randomly --no-cov -q 2>&1)
  t1=$(date +%s); wall=$((t1-t0))
  summary=$(echo "$out" | grep -E '[0-9]+ (passed|failed|error)' | tail -1)
  secs=$(echo "$summary" | grep -oE 'in [0-9.]+s' | grep -oE '[0-9.]+' | tail -1)
  passed=$(echo "$summary" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | head -1)
  failed=$(echo "$summary" | grep -oE '[0-9]+ (failed|error)' | grep -oE '[0-9]+' | head -1)
  if echo "$summary" | grep -qE 'failed|error'; then res=FAIL; else res=PASS; fi
  printf '%s\tserial\t0\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ARM" "$r" "${secs:-NA}" "$wall" "${passed:-0}" "${failed:-0}" "$res" >> "$TSV"
  log "SERIAL(-n0) run$r: pytest=${secs}s wall=${wall}s passed=${passed} failed=${failed} $res"
  sleep 3
done
docker rm -f "$PG" "$RD" >/dev/null 2>&1 || true
log "SERIAL $ARM DONE"
