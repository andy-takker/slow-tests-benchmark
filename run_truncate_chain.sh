#!/usr/bin/env bash
# Цепочка с TRUNCATE как ИЗНАЧАЛЬНОЙ очисткой (DELETE появляется только как 3-я правка).
# Досниманием недостающие точки:
#   S0 = function-scope + боевой argon2 + TRUNCATE  (RUNS=1 — дисперсия function-scope <3%)
#   S1 = session-scope  + боевой argon2 + TRUNCATE  (RUNS=2)
# S2 (session+быстрый argon2+TRUNCATE) и S3 (session+быстрый argon2+DELETE) уже есть.
set -uo pipefail
cd "$(dirname "$0")/.."
export APP_DATABASE_PORT=5433 APP_REDIS_DSN=redis://127.0.0.1:6380
RESULTS="benchmark/results"
TOUCHED=(pyproject.toml tests/conftest.py tests/plugins/instances)
restore() { git checkout -- "${TOUCHED[@]}"; }
trap restore EXIT
now() { python3 -c 'import time; print(f"{time.time():.2f}")'; }

echo "variant,run,wall_seconds,exit_code" > "$RESULTS/truncate_chain_times.csv"
run() {  # $1=name  $2=runs (reverts уже применены)
  for i in $(seq 1 "$2"); do
    s=$(now); c=0
    .venv/bin/pytest ./tests -p no:randomly -q --junitxml="$RESULTS/${1}_run${i}.xml" \
      > "$RESULTS/${1}_run${i}.log" 2>&1 || c=$?
    e=$(now); el=$(python3 -c "print(f'{$e - $s:.1f}')")
    echo "${1},${i},${el},${c}" >> "$RESULTS/truncate_chain_times.csv"
    echo "    ${1} run${i}: ${el}s (exit ${c})"
  done
}

echo ">>> S0 = function + боевой argon2 + TRUNCATE"
restore
python3 benchmark/apply_variant.py function_scope
python3 benchmark/apply_variant.py argon2_default
python3 benchmark/apply_variant.py truncate
run s0_func_default_truncate 1

echo ">>> S1 = session + боевой argon2 + TRUNCATE"
restore
python3 benchmark/apply_variant.py argon2_default
python3 benchmark/apply_variant.py truncate
run s1_session_default_truncate 2

restore
echo "Готово:"; column -s, -t "$RESULTS/truncate_chain_times.csv"
