#!/usr/bin/env bash
# v0 = проект БЕЗ оптимизаций: function-scope фикстуры/loop + боевой argon2.
# Снимаем на нём cProfile (тут он показателен) и полное время прогона.
set -uo pipefail
cd "$(dirname "$0")/.."

export APP_DATABASE_PORT=5433 APP_REDIS_DSN=redis://127.0.0.1:6380
PYTEST=".venv/bin/pytest"
PYTHON=".venv/bin/python"
RESULTS="benchmark/results"
RUNS="${RUNS:-2}"
TOUCHED=(pyproject.toml tests/conftest.py tests/plugins/instances)
PROFILE_SUBSET=(
  tests/use_cases/auth
  tests/use_cases/admin_tokens
  tests/use_cases/notifications
  tests/adapters/database
)

mkdir -p "$RESULTS"
restore() { git checkout -- "${TOUCHED[@]}"; }
trap restore EXIT
restore

# Применяем ОБА отката -> состояние "до всех оптимизаций"
python3 benchmark/apply_variant.py function_scope
python3 benchmark/apply_variant.py argon2_default

echo ">>> cProfile на подвыборке (${PROFILE_SUBSET[*]}) в неоптимизированном состоянии"
$PYTHON -m cProfile -o "$RESULTS/profile_v0.out" -m pytest "${PROFILE_SUBSET[@]}" \
  -p no:randomly -q > "$RESULTS/profile_v0_pytest.log" 2>&1 || true
echo "    профиль сохранён: $RESULTS/profile_v0.out"

now() { python3 -c 'import time; print(f"{time.time():.2f}")'; }
echo "variant,run,wall_seconds,exit_code" > "$RESULTS/v0_times.csv"
for i in $(seq 1 "$RUNS"); do
  echo ">>> v0 (no optimizations): полный прогон ${i}/${RUNS}"
  start=$(now); code=0
  $PYTEST ./tests -p no:randomly -q --junitxml="$RESULTS/v0_run${i}.xml" \
    > "$RESULTS/v0_run${i}.log" 2>&1 || code=$?
  end=$(now)
  elapsed=$(python3 -c "print(f'{$end - $start:.1f}')")
  echo "v0,${i},${elapsed},${code}" >> "$RESULTS/v0_times.csv"
  echo "    ${elapsed}s (exit ${code})"
done

restore
echo "Готово v0:"; column -s, -t "$RESULTS/v0_times.csv"
