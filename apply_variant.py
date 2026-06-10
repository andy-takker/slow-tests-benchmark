#!/usr/bin/env python3
"""Применяет вариант бенчмарка к рабочей копии точечными заменами.

Каждый вариант — это «откат» одной оптимизации тестов к состоянию «до».
Восстановление: git checkout -- <files> (делает run.sh).

Использование: python3 benchmark/apply_variant.py <variant>
Варианты: function_scope | argon2_default | truncate
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PYPROJECT = ROOT / "pyproject.toml"
CONFTEST = ROOT / "tests" / "conftest.py"
DB = ROOT / "tests" / "plugins" / "instances" / "db.py"
CRYPT = ROOT / "tests" / "plugins" / "instances" / "crypt.py"
REDIS = ROOT / "tests" / "plugins" / "instances" / "redis.py"
REST = ROOT / "tests" / "plugins" / "instances" / "rest.py"


def replace(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if old not in text:
        sys.exit(f"ОШИБКА: в {path} не найден ожидаемый фрагмент:\n---\n{old}\n---")
    path.write_text(text.replace(old, new, 1))


def function_scope() -> None:
    """Откат session-scope к function (как до оптимизации).

    Сносим session loop scope и ВСЕ session-scoped фикстуры в plugins/instances:
    с function loop любая оставшаяся session-scoped async-фикстура (или session
    фикстура, зависящая от неё) валит pytest-asyncio с ScopeMismatch. Это и есть
    честный counterfactual «session-scope оптимизации нет вообще».
    """
    replace(
        PYPROJECT,
        'asyncio_default_fixture_loop_scope = "session"\n'
        'asyncio_default_test_loop_scope = "session"',
        'asyncio_default_fixture_loop_scope = "function"\n'
        'asyncio_default_test_loop_scope = "function"',
    )
    instances = ROOT / "tests" / "plugins" / "instances"
    marker = '@pytest.fixture(scope="session")'
    count = 0
    for py in sorted(instances.rglob("*.py")):
        text = py.read_text()
        if marker in text:
            py.write_text(text.replace(marker, "@pytest.fixture"))
            count += text.count(marker)
    if count == 0:
        sys.exit(f"ОШИБКА: не найдено ни одной session-фикстуры в {instances}")
    print(f"  понижено session→function фикстур: {count}")


def argon2_default() -> None:
    """Откат к боевым (медленным) параметрам argon2."""
    replace(
        CONFTEST,
        "import passlib.hash\n"
        "\n"
        "# Speed up argon2 hashing in tests: minimum cost parameters.\n"
        "# Defaults are intentionally slow for production (~100ms+ per hash); for tests\n"
        "# we only care about the round-trip working, not cryptographic strength.\n"
        "passlib.hash.argon2.default_rounds = 1\n"
        "passlib.hash.argon2.default_memory_cost = 8\n"
        "passlib.hash.argon2.default_parallelism = 1\n"
        "\n",
        "",
    )
    replace(
        CRYPT,
        "    return CryptContext(\n"
        '        schemes=["argon2"],\n'
        '        deprecated="auto",\n'
        "        argon2__rounds=1,\n"
        "        argon2__memory_cost=8,\n"
        "        argon2__parallelism=1,\n"
        "    )",
        '    return CryptContext(schemes=["argon2"], deprecated="auto")',
    )


def truncate() -> None:
    """Очистка через один TRUNCATE ... CASCADE вместо DELETE по таблицам."""
    replace(
        DB,
        "_DELETE_STATEMENTS = tuple(\n"
        "    text(f'DELETE FROM \"{t.name}\"') for t in reversed(BaseTable.metadata.sorted_tables)\n"
        ")",
        '_TRUNCATE_SQL = "TRUNCATE {} RESTART IDENTITY CASCADE".format(\n'
        '    ", ".join(f\'"{t.name}"\' for t in reversed(BaseTable.metadata.sorted_tables))\n'
        ")",
    )
    replace(
        DB,
        "    async with engine.begin() as conn:\n"
        "        for stmt in _DELETE_STATEMENTS:\n"
        "            await conn.execute(stmt)",
        "    async with engine.begin() as conn:\n"
        "        await conn.execute(text(_TRUNCATE_SQL))",
    )


VARIANTS = {
    "function_scope": function_scope,
    "argon2_default": argon2_default,
    "truncate": truncate,
}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in VARIANTS:
        sys.exit(f"Использование: {sys.argv[0]} {{{' | '.join(VARIANTS)}}}")
    VARIANTS[sys.argv[1]]()
    print(f"Вариант '{sys.argv[1]}' применён.")
