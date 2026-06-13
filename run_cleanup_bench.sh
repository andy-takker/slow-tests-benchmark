#!/usr/bin/env bash
# A5½ cleanup microbenchmark runner (Tishka17's comment).
# Spins a fresh Postgres (same image/limits as the xdist arms), runs
# cleanup_bench.py, tears the container down. Idempotent.
set -uo pipefail
BENCH="$(cd "$(dirname "$0")" && pwd)"
LMS="${PROJECT_DIR:?set PROJECT_DIR to your backend repo}"
cd "$LMS"

PG=lms-bench-pg
export APP_DATABASE_HOST=127.0.0.1 APP_DATABASE_PORT=5434 \
       APP_DATABASE_USER=lms APP_DATABASE_PASSWORD=lms APP_DATABASE_NAME=lms

echo "[$(date +%H:%M:%S)] fresh postgres…"
docker rm -fv "$PG" >/dev/null 2>&1 || true
docker run -d --rm --name "$PG" --memory=3g --memory-swap=3g \
  -e POSTGRES_USER=lms -e POSTGRES_PASSWORD=lms -e POSTGRES_DB=lms \
  -p 5434:5432 postgres:latest -c max_connections=300 >/dev/null

for i in $(seq 1 40); do
  docker exec "$PG" pg_isready -U lms >/dev/null 2>&1 && break; sleep 1
done
docker exec "$PG" psql -U lms -d lms -tAc 'select 1' >/dev/null || {
  echo "FATAL: pg not reachable"; docker rm -fv "$PG" >/dev/null 2>&1; exit 1; }

echo "[$(date +%H:%M:%S)] running microbench…"
BENCH_WARMUP="${BENCH_WARMUP:-5}" BENCH_CYCLES="${BENCH_CYCLES:-40}" \
  "$LMS/.venv/bin/python" "$BENCH/cleanup_bench.py"
rc=$?

echo "[$(date +%H:%M:%S)] teardown"
docker rm -fv "$PG" >/dev/null 2>&1 || true
exit $rc
