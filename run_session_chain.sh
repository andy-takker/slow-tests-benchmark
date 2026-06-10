#!/usr/bin/env bash
# Все session-scope точки В ОДНОМ ПРОГОНЕ -> внутренне сопоставимые числа
# (без межсессионного дрейфа). S0 (function-scope, ~30 мин) переиспользуем отдельно.
#   a1 = session + боевой  argon2 + TRUNCATE   (apply argon2_default + truncate)
#   a2 = session + быстрый argon2 + TRUNCATE   (apply truncate)
#   a3 = session + быстрый argon2 + DELETE     (ничего — это итог/baseline)
set -uo pipefail
cd "$(dirname "$0")/.."
export APP_DATABASE_PORT=5433 APP_REDIS_DSN=redis://127.0.0.1:6380
RESULTS="benchmark/results"
RUNS="${RUNS:-2}"
TOUCHED=(pyproject.toml tests/conftest.py tests/plugins/instances)
restore() { git checkout -- "${TOUCHED[@]}"; }
trap restore EXIT
now() { python3 -c 'import time; print(f"{time.time():.2f}")'; }

echo "variant,run,wall_seconds,exit_code" > "$RESULTS/session_chain_times.csv"
run() {  # $1=name (reverts уже применены)
  for i in $(seq 1 "$RUNS"); do
    s=$(now); c=0
    .venv/bin/pytest ./tests -p no:randomly -q --junitxml="$RESULTS/${1}_run${i}.xml" \
      > "$RESULTS/${1}_run${i}.log" 2>&1 || c=$?
    e=$(now); el=$(python3 -c "print(f'{$e - $s:.1f}')")
    echo "${1},${i},${el},${c}" >> "$RESULTS/session_chain_times.csv"
    echo "    ${1} run${i}: ${el}s (exit ${c})"
  done
}

echo ">>> a1 = session + боевой argon2 + TRUNCATE"
restore; python3 benchmark/apply_variant.py argon2_default; python3 benchmark/apply_variant.py truncate
run a1_session_default_truncate

echo ">>> a2 = session + быстрый argon2 + TRUNCATE"
restore; python3 benchmark/apply_variant.py truncate
run a2_session_fast_truncate

echo ">>> a3 = session + быстрый argon2 + DELETE (итог)"
restore
run a3_session_fast_delete

restore
echo "Готово:"; column -s, -t "$RESULTS/session_chain_times.csv"
