#!/usr/bin/env bash
# Бенчмарк тестов проекта: baseline + откат каждой оптимизации по отдельности.
#
# Требования: поднятые dev-контейнеры (make local), .venv с зависимостями.
# Запуск:   bash benchmark/run.sh
# Опции:    RUNS=3 bash benchmark/run.sh        # прогонов на вариант (default 2)
#           VARIANTS="baseline truncate" bash benchmark/run.sh
#
# Результаты: benchmark/results/times.csv + лог и junit на каждый прогон.

set -euo pipefail
cd "$(dirname "$0")/.."

PYTEST="${PYTEST:-.venv/bin/pytest}"
RUNS="${RUNS:-2}"
VARIANTS="${VARIANTS:-baseline truncate argon2_default function_scope}"
RESULTS="benchmark/results"
TOUCHED_FILES=(
  pyproject.toml
  tests/conftest.py
  tests/plugins/instances
)

mkdir -p "$RESULTS"
[ -f "$RESULTS/times.csv" ] || echo "variant,run,wall_seconds,exit_code" > "$RESULTS/times.csv"

restore() { git checkout -- "${TOUCHED_FILES[@]}"; }
trap restore EXIT

# Файлы вариантов не должны иметь локальных правок — иначе restore их затрёт.
if ! git diff --quiet -- "${TOUCHED_FILES[@]}"; then
  echo "ОШИБКА: есть незакоммиченные правки в файлах, которые трогает бенчмарк:" >&2
  git diff --name-only -- "${TOUCHED_FILES[@]}" >&2
  exit 1
fi

now() { python3 -c 'import time; print(f"{time.time():.2f}")'; }

run_variant() {
  local name="$1"
  restore
  if [ "$name" != "baseline" ]; then
    python3 benchmark/apply_variant.py "$name"
  fi
  for i in $(seq 1 "$RUNS"); do
    echo ">>> ${name}: прогон ${i}/${RUNS}"
    local start end code elapsed
    start=$(now)
    code=0
    "$PYTEST" ./tests -p no:randomly -q \
      --junitxml="$RESULTS/${name}_run${i}.xml" \
      > "$RESULTS/${name}_run${i}.log" 2>&1 || code=$?
    end=$(now)
    elapsed=$(python3 -c "print(f'{$end - $start:.1f}')")
    echo "${name},${i},${elapsed},${code}" >> "$RESULTS/times.csv"
    echo "    ${elapsed}s (exit ${code})"
  done
}

for v in $VARIANTS; do
  run_variant "$v"
done

restore
echo
echo "Готово. Сводка:"
column -s, -t "$RESULTS/times.csv"
