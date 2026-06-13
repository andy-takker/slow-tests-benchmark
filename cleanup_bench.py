#!/usr/bin/env python3
# A5½ — between-test DB cleanup microbenchmark (answers Tishka17's comment).
#
# Measures the PER-TEST cost of three "reset the DB between tests" strategies,
# reusing the real project schema (lms BaseTable.metadata, ~150 tables):
#
#   delete    — DELETE FROM every table, reverse FK order, one transaction
#               (the production-optimized path: reuses the session-scope pool)
#   truncate  — TRUNCATE <all> RESTART IDENTITY CASCADE, one transaction
#               (reuses the pool too; DDL with ACCESS EXCLUSIVE + catalog work)
#   template  — the "honest" per-test isolation: DROP DATABASE + CREATE DATABASE
#               ... TEMPLATE. CREATE ... TEMPLATE needs ZERO connections to the
#               db, but a session-scope pool holds them — so each cycle must
#               dispose the pool, recreate the db, then reconnect and issue the
#               first query. That reconnect is the "входной налог" returning.
#
# State is the realistic per-test one: near-empty tables (a test writes a few
# rows, the fixture wipes them). We measure on the empty schema, which isolates
# the structural cost (per-table iteration / DDL on N tables / db clone +
# reconnect) from row volume — exactly the regime the comment debates.
#
# Output: per-strategy median/min/max/mean ms per cycle -> stdout + results CSV.
import asyncio
import os
import statistics
import sys
import time

import asyncpg
from sqlalchemy import text

sys.path.insert(0, os.environ.get("PROJECT_DIR", "."))

from lms.adapters.database.config import DatabaseConfig  # noqa: E402
from lms.adapters.database.tables import BaseTable  # noqa: E402
from lms.adapters.database.utils import create_engine  # noqa: E402

BASE_DB = os.environ.get("APP_DATABASE_NAME", "lms")
TEMPLATE_DB = "bench_template"
WORK_DB = "bench_work"
WARMUP = int(os.environ.get("BENCH_WARMUP", 5))
CYCLES = int(os.environ.get("BENCH_CYCLES", 40))
POOL_SIZE = int(os.environ.get("BENCH_POOL_SIZE", 5))

_DELETE_STMTS = tuple(
    text(f'DELETE FROM "{t.name}"') for t in reversed(BaseTable.metadata.sorted_tables)
)
_TRUNCATE_STMT = text(
    "TRUNCATE "
    + ", ".join(f'"{t.name}"' for t in BaseTable.metadata.sorted_tables)
    + " RESTART IDENTITY CASCADE"
)


def cfg(database: str) -> DatabaseConfig:
    return DatabaseConfig(
        host=os.environ.get("APP_DATABASE_HOST", "127.0.0.1"),
        port=int(os.environ.get("APP_DATABASE_PORT", 5434)),
        user=os.environ.get("APP_DATABASE_USER", "lms"),
        password=os.environ.get("APP_DATABASE_PASSWORD", "lms"),
        database=database,
        pool_size=POOL_SIZE,
        max_overflow=POOL_SIZE,
    )


async def _admin():
    c = cfg(BASE_DB)
    return await asyncpg.connect(
        host=c.host, port=c.port, user=c.user, password=c.password, database=c.database
    )


async def _drop_create_work_from_template(admin: asyncpg.Connection) -> None:
    # Reuse one persistent admin connection (it never touches WORK_DB/TEMPLATE_DB,
    # so DROP ... FORCE and CREATE ... TEMPLATE keep their zero-connection
    # guarantee). Avoids a spurious per-cycle connect that would inflate the
    # template number we use to argue against per-test template isolation.
    await admin.execute(f'DROP DATABASE IF EXISTS "{WORK_DB}" WITH (FORCE)')
    await admin.execute(f'CREATE DATABASE "{WORK_DB}" TEMPLATE "{TEMPLATE_DB}"')


async def build_template(admin: asyncpg.Connection) -> None:
    await admin.execute(f'DROP DATABASE IF EXISTS "{WORK_DB}" WITH (FORCE)')
    await admin.execute(f'DROP DATABASE IF EXISTS "{TEMPLATE_DB}" WITH (FORCE)')
    await admin.execute(f'CREATE DATABASE "{TEMPLATE_DB}"')
    # create_all into the template once; dispose so nothing holds the template.
    c = cfg(TEMPLATE_DB)
    async with create_engine(
        dsn=str(c.dsn), debug=False, pool_size=2, pool_timeout=10, max_overflow=0
    ) as engine:
        async with engine.begin() as conn:
            await conn.run_sync(BaseTable.metadata.create_all)


async def bench_pool_strategy(kind: str, admin: asyncpg.Connection) -> list[float]:
    # delete / truncate: reuse one long-lived pool (session-scope analogue).
    await _drop_create_work_from_template(admin)
    c = cfg(WORK_DB)
    samples: list[float] = []
    async with create_engine(
        dsn=str(c.dsn),
        debug=False,
        pool_size=POOL_SIZE,
        pool_timeout=10,
        max_overflow=POOL_SIZE,
    ) as engine:
        for i in range(WARMUP + CYCLES):
            t0 = time.perf_counter()
            async with engine.begin() as conn:
                if kind == "delete":
                    for stmt in _DELETE_STMTS:
                        await conn.execute(stmt)
                else:
                    await conn.execute(_TRUNCATE_STMT)
            dt = (time.perf_counter() - t0) * 1000
            if i >= WARMUP:
                samples.append(dt)
    return samples


async def bench_template_strategy(admin: asyncpg.Connection) -> list[float]:
    # honest per-test isolation: each cycle disposes the pool, recreates the db
    # from template, then reconnects + first query. Pool churn is the point.
    c = cfg(WORK_DB)
    samples: list[float] = []
    for i in range(WARMUP + CYCLES):
        t0 = time.perf_counter()
        # 1) tear the pool down — CREATE DATABASE ... TEMPLATE needs zero conns
        await _drop_create_work_from_template(admin)
        # 2) bring a fresh pool up and pay for the first real query (reconnect)
        async with create_engine(
            dsn=str(c.dsn),
            debug=False,
            pool_size=POOL_SIZE,
            pool_timeout=10,
            max_overflow=POOL_SIZE,
        ) as engine:
            async with engine.begin() as conn:
                await conn.execute(text("SELECT 1"))
        dt = (time.perf_counter() - t0) * 1000
        if i >= WARMUP:
            samples.append(dt)
    return samples


def report(name: str, s: list[float]) -> str:
    med, mn, mx = statistics.median(s), min(s), max(s)
    mean = statistics.mean(s)
    print(
        f"  {name:10s} median={med:8.2f}ms  min={mn:8.2f}  max={mx:8.2f}  "
        f"mean={mean:8.2f}  (n={len(s)})"
    )
    return f"{name},{med:.3f},{mn:.3f},{mx:.3f},{mean:.3f},{len(s)}\n"


async def main() -> None:
    ntables = len(BaseTable.metadata.sorted_tables)
    print(
        f"A5½ cleanup microbench — {ntables} tables, ZERO rows (near-empty "
        f"per-test state), WARMUP={WARMUP} CYCLES={CYCLES} pool_size={POOL_SIZE}"
    )
    admin = await _admin()
    await build_template(admin)
    delete = await bench_pool_strategy("delete", admin)
    truncate = await bench_pool_strategy("truncate", admin)
    template = await bench_template_strategy(admin)
    print("\nPER-CYCLE CLEANUP COST (ms):")
    rows = "strategy,median_ms,min_ms,max_ms,mean_ms,cycles\n"
    rows += report("delete", delete)
    rows += report("truncate", truncate)
    rows += report("template", template)
    md = statistics.median(delete)
    print("\nrelative to DELETE (median):")
    for name, s in (("truncate", truncate), ("template", template)):
        f = statistics.median(s) / md
        print(f"  {name:10s} ×{f:5.2f}  ({statistics.median(s) - md:+.2f}ms/cycle)")
    out = os.environ.get(
        "BENCH_OUT",
        os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "results", "cleanup_bench.csv"
        ),
    )
    with open(out, "w") as fh:
        fh.write(rows)
    print(f"\nwrote {out}")
    # cleanup — reuse the persistent admin conn, then close it.
    try:
        await admin.execute(f'DROP DATABASE IF EXISTS "{WORK_DB}" WITH (FORCE)')
        await admin.execute(f'DROP DATABASE IF EXISTS "{TEMPLATE_DB}" WITH (FORCE)')
    finally:
        await admin.close()


if __name__ == "__main__":
    asyncio.run(main())
