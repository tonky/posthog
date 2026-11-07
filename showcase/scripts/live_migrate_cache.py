"""Live Postgres (routed apps) and ClickHouse DDL migration snapshot cache helpers.

Provides deterministic key computation, canonical DDL tokenization and topological
ordering, atomic generation publishing/verification, and incremental subset base
selection for ``live_posthog.sh`` and CI rolling-cache validation.
"""

from __future__ import annotations

import argparse
import collections
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Iterator

PG_FORMAT_PREFIX = "enact-live-pg-v1"
CH_FORMAT_PREFIX = "enact-live-ch-v1"
PG_REQUIRED_FILES = ("live-postgres.dump", "live-migrations.json")
CH_REQUIRED_FILES = ("ddl.json", "migrations.json", "seed_rows.json")

TOKEN_CH_DB = "__ENACT_CH_DB__"
TOKEN_KAFKA_PREFIX = "__ENACT_KAFKA_PREFIX__"
TOKEN_KAFKA_BROKER = "__ENACT_KAFKA_BROKER__"
TOKEN_CH_ZK = "__ENACT_CH_ZK__"

MAX_SEED_TABLE_ROWS = 50_000
_POINTER_NAME = "current-v1"
_GEN_RE = re.compile(r"^v1\.[0-9A-Za-z._-]+$")
_KEY_RE = re.compile(r"^[a-f0-9]{64}$")
_CREATE_UUID_RE = re.compile(
    r"^(CREATE\s+(?:TABLE|VIEW|MATERIALIZED\s+VIEW|LIVE\s+VIEW|WINDOW\s+VIEW|DICTIONARY)"
    r"\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:`[^`]+`|\S+))\s+UUID\s+'[0-9a-fA-F-]+'",
    re.IGNORECASE,
)
_ZK_PATH_RE = re.compile(r"'/clickhouse/tables/(?:[0-9a-fA-F-]+_)?([^']*)'")
_VIEW_ENGINES = frozenset({"MaterializedView", "View", "LiveView", "WindowView"})
_OVERLAY_ENGINES = frozenset({"Buffer", "Distributed"})


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


@contextlib.contextmanager
def file_lock(lock_path: Path) -> Iterator[None]:
    """Acquire an exclusive advisory flock on ``lock_path``."""
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _hash_paths(repo_root: Path, paths: list[Path], extra: list[str]) -> str:
    digest = hashlib.sha256()
    for item in extra:
        digest.update(item.encode("utf-8"))
        digest.update(b"\0")
    seen: set[Path] = set()
    for path in sorted(paths):
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        rel = path.relative_to(repo_root).as_posix()
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        digest.update(sha256_file(path).encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def _parse_pointer(key_dir: Path) -> Path | None:
    pointer = key_dir / _POINTER_NAME
    if not pointer.is_file():
        return None
    lines = pointer.read_text(encoding="utf-8", errors="replace").splitlines()
    if len(lines) != 1:
        return None
    target_name = lines[0].strip()
    if not _GEN_RE.fullmatch(target_name):
        return None
    gen_dir = key_dir / target_name
    return gen_dir if gen_dir.is_dir() else None


def verify_generation(
    gen_dir: Path,
    format_prefix: str,
    expected_key: str,
    required_files: tuple[str, ...],
) -> str | None:
    """Validate manifest, checksums, and non-empty required artifacts; return runtime tag on success."""
    manifest_path = gen_dir / "manifest"
    if not manifest_path.is_file():
        return None
    try:
        lines = manifest_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    if not lines:
        return None
    header_parts = lines[0].split(" ", 1)
    if header_parts[0] != f"{format_prefix}:{expected_key}":
        return None
    runtime_tag = header_parts[1].strip() if len(header_parts) > 1 else ""
    recorded: dict[str, str] = {}
    for entry in lines[1:]:
        if "  " not in entry:
            return None
        digest, name = entry.split("  ", 1)
        if name not in required_files or name in recorded:
            return None
        if not re.fullmatch(r"[a-f0-9]{64}", digest):
            return None
        recorded[name] = digest
    if set(recorded) != set(required_files):
        return None
    for name, expected_hash in recorded.items():
        candidate = gen_dir / name
        if not candidate.is_file() or candidate.stat().st_size == 0:
            return None
        if sha256_file(candidate) != expected_hash:
            return None
    return runtime_tag


def resolve_verified_generation(
    store_root: Path,
    format_prefix: str,
    key: str,
    required_files: tuple[str, ...],
    expected_runtime_tag: str | None = None,
) -> Path | None:
    """Return verified ``current-v1`` generation dir for ``key``, or ``None``."""
    if not _KEY_RE.fullmatch(key):
        return None
    key_dir = store_root / key
    gen_dir = _parse_pointer(key_dir)
    if gen_dir is None:
        return None
    runtime_tag = verify_generation(gen_dir, format_prefix, key, required_files)
    if runtime_tag is None:
        return None
    if expected_runtime_tag is not None and runtime_tag != expected_runtime_tag:
        return None
    return gen_dir


def publish_generation(
    store_root: Path,
    format_prefix: str,
    key: str,
    runtime_tag: str,
    files: dict[str, bytes],
) -> Path:
    """Atomically stage ``files`` + ``manifest`` into ``v1.<uuid>`` and swap ``current-v1``."""
    key_dir = store_root / key
    key_dir.mkdir(parents=True, exist_ok=True)
    gen_name = f"v1.{uuid.uuid4().hex[:8]}"
    stage_dir = key_dir / f".staging-{gen_name}"
    final_dir = key_dir / gen_name
    stage_dir.mkdir(parents=True, exist_ok=True)
    try:
        manifest_lines = [f"{format_prefix}:{key} {runtime_tag}".rstrip()]
        for name in sorted(files):
            payload = files[name]
            if not payload:
                raise ValueError(f"refusing to publish empty artifact {name}")
            (stage_dir / name).write_bytes(payload)
            manifest_lines.append(f"{sha256_bytes(payload)}  {name}")
        (stage_dir / "manifest").write_text("\n".join(manifest_lines) + "\n", encoding="utf-8")
        stage_dir.rename(final_dir)
        pointer_tmp = key_dir / f".{_POINTER_NAME}.{uuid.uuid4().hex[:8]}"
        pointer_tmp.write_text(f"{gen_name}\n", encoding="utf-8")
        pointer_tmp.replace(key_dir / _POINTER_NAME)
        for child in key_dir.iterdir():
            if child.name == gen_name or child.name in {_POINTER_NAME} or child.name.endswith(".lock"):
                continue
            if child.is_dir() and (child.name.startswith("v1.") or child.name.startswith(".staging-")):
                shutil.rmtree(child, ignore_errors=True)
            elif child.is_file() and child.name.startswith(f".{_POINTER_NAME}."):
                child.unlink(missing_ok=True)
    except Exception:
        shutil.rmtree(stage_dir, ignore_errors=True)
        shutil.rmtree(final_dir, ignore_errors=True)
        raise
    return final_dir


def verify_store(store_root: Path, format_prefix: str, required_files: tuple[str, ...]) -> tuple[bool, list[str]]:
    """Audit every key directory in ``store_root``; return ``(has_any_valid, errors)``."""
    if not store_root.exists():
        return False, []
    if not store_root.is_dir():
        return False, [f"{store_root} is not a directory"]
    has_valid = False
    errors: list[str] = []
    for entry in sorted(store_root.iterdir()):
        if entry.name.endswith(".lock") and entry.is_file():
            continue
        if not entry.is_dir() or not _KEY_RE.fullmatch(entry.name):
            errors.append(f"unexpected entry {entry}")
            continue
        pointer = entry / _POINTER_NAME
        if not pointer.exists():
            # A crashed staging dir or empty lock-only key directory without current-v1 cannot be transported cleanly.
            children = [p.name for p in entry.iterdir() if not p.name.endswith(".lock")]
            if children:
                errors.append(f"missing {_POINTER_NAME} in {entry}")
            continue
        gen_dir = _parse_pointer(entry)
        if gen_dir is None:
            errors.append(f"invalid {_POINTER_NAME} in {entry}")
            continue
        if verify_generation(gen_dir, format_prefix, entry.name, required_files) is None:
            errors.append(f"corrupt generation {gen_dir}")
            continue
        has_valid = True
    return has_valid, errors


# ---------------------------------------------------------------------------
# Postgres routed live-migration cache helpers
# ---------------------------------------------------------------------------


def routed_apps(repo_root: Path) -> list[str]:
    """Return sorted unique ``app_label`` entries from ``products/db_routing.yaml``."""
    routing = repo_root / "products" / "db_routing.yaml"
    if not routing.is_file():
        return []
    return sorted(set(re.findall(r"app_label:\s*(\w+)", routing.read_text(encoding="utf-8"))))


def repo_pg_migration_files(repo_root: Path) -> list[Path]:
    """Collect Django migration files under ``posthog/``, ``ee/``, and ``products/``."""
    files: list[Path] = []
    for base in (repo_root / "posthog" / "migrations", repo_root / "ee" / "migrations"):
        if base.is_dir():
            files.extend(p for p in base.rglob("*.py") if "__pycache__" not in p.parts)
    products_dir = repo_root / "products"
    if products_dir.is_dir():
        for mig_dir in products_dir.glob("*/migrations"):
            files.extend(p for p in mig_dir.rglob("*.py") if "__pycache__" not in p.parts)
        for mig_dir in products_dir.glob("*/backend/migrations"):
            files.extend(p for p in mig_dir.rglob("*.py") if "__pycache__" not in p.parts)
    return sorted(set(files))


def repo_pg_migrations(repo_root: Path) -> tuple[set[str], set[tuple[str, str]]]:
    """Return ``(repo_app_labels, {(app, migration_stem)})`` present on disk."""
    apps: set[str] = set()
    pairs: set[tuple[str, str]] = set()
    for path in repo_pg_migration_files(repo_root):
        if path.name == "__init__.py":
            continue
        rel_parts = path.relative_to(repo_root).parts
        if rel_parts[0] in {"posthog", "ee"}:
            app = rel_parts[0]
        elif rel_parts[0] == "products" and len(rel_parts) >= 3:
            app = rel_parts[1]
        else:
            continue
        apps.add(app)
        pairs.add((app, path.stem))
    return apps, pairs


def compute_pg_key(repo_root: Path, template_key: str, pg_major: str) -> str:
    """Compute deterministic cache key for routed live Postgres migrations."""
    apps = routed_apps(repo_root)
    paths = [
        repo_root / "products" / "db_routing.yaml",
        repo_root / "showcase" / "scripts" / "live_posthog.sh",
        repo_root / "showcase" / "scripts" / "live_migrate_cache.py",
        *repo_pg_migration_files(repo_root),
    ]
    extra = [
        "live-pg-v1",
        f"template_key={template_key}",
        f"pg_major={pg_major}",
        f"routed_apps={','.join(apps)}",
    ]
    return _hash_paths(repo_root, paths, extra)


def select_pg_base(
    store_root: Path,
    repo_root: Path,
    template_key: str,
    pg_major: str,
) -> Path | None:
    """Select the newest verified live-pg snapshot whose applied migrations are a subset of disk."""
    if not store_root.is_dir():
        return None
    current_routed = routed_apps(repo_root)
    repo_apps, current_pairs = repo_pg_migrations(repo_root)
    runtime_tag = f"pg{pg_major}"
    best: tuple[tuple[int, int, float], Path] | None = None
    for entry in store_root.iterdir():
        if not entry.is_dir() or not _KEY_RE.fullmatch(entry.name):
            continue
        gen_dir = resolve_verified_generation(
            store_root, PG_FORMAT_PREFIX, entry.name, PG_REQUIRED_FILES, expected_runtime_tag=runtime_tag
        )
        if gen_dir is None:
            continue
        try:
            meta = json.loads((gen_dir / "live-migrations.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if meta.get("routed_apps") != current_routed:
            continue
        applied = meta.get("applied")
        if not isinstance(applied, list) or not applied:
            continue
        compatible = True
        for row in applied:
            if not (isinstance(row, list) and len(row) == 2 and all(isinstance(x, str) for x in row)):
                compatible = False
                break
            app, name = row[0], row[1]
            if app in repo_apps and (app, name) not in current_pairs:
                compatible = False
                break
        if not compatible:
            continue
        same_template = 1 if meta.get("template_key") == template_key else 0
        rank = (same_template, len(applied), gen_dir.stat().st_mtime)
        if best is None or rank > best[0]:
            best = (rank, gen_dir)
    return best[1] if best else None


# ---------------------------------------------------------------------------
# ClickHouse canonical DDL + migration snapshot cache helpers
# ---------------------------------------------------------------------------


def parse_ch_major_minor(version_output: str) -> str:
    """Extract ``major.minor`` from ClickHouse version string or server SELECT version()."""
    match = re.search(r"(\d+)\.(\d+)", version_output)
    if not match:
        raise ValueError(f"Cannot parse ClickHouse version from {version_output!r}")
    return f"{match.group(1)}.{match.group(2)}"


def _uv_lock_package_block(uv_lock: Path, package_names: tuple[str, ...]) -> str:
    if not uv_lock.is_file():
        return ""
    blocks = uv_lock.read_text(encoding="utf-8").split("\n[[package]]\n")
    matched = []
    for block in blocks:
        for pkg in package_names:
            if f'name = "{pkg}"' in block:
                matched.append(block)
                break
    return "\n".join(sorted(matched))


def ch_migration_files(repo_root: Path) -> list[Path]:
    """Return sorted ClickHouse migration source files."""
    files: list[Path] = []
    for base in (repo_root / "posthog" / "clickhouse" / "migrations", repo_root / "ee" / "clickhouse" / "migrations"):
        if base.is_dir():
            files.extend(p for p in base.rglob("*.py") if "__pycache__" not in p.parts)
    products_dir = repo_root / "products"
    if products_dir.is_dir():
        for ch_dir in products_dir.glob("*/clickhouse"):
            files.extend(p for p in ch_dir.rglob("*.py") if "__pycache__" not in p.parts)
    return sorted(set(files))


def repo_ch_migrations(repo_root: Path) -> set[tuple[str, str]]:
    """Return ``{(package_name, module_stem)}`` for ClickHouse migrations on disk."""
    pairs: set[tuple[str, str]] = set()
    for path in ch_migration_files(repo_root):
        if path.name == "__init__.py":
            continue
        rel = path.relative_to(repo_root).parts
        if len(rel) >= 4 and rel[0] in {"posthog", "ee"} and rel[1] == "clickhouse" and rel[2] == "migrations":
            pkg = f"{rel[0]}.clickhouse.migrations"
            pairs.add((pkg, path.stem))
        elif len(rel) >= 4 and rel[0] == "products" and rel[2] == "clickhouse":
            pkg = ".".join(rel[:-1])
            pairs.add((pkg, path.stem))
    return pairs


def compute_ch_key(repo_root: Path, ch_version: str) -> str:
    """Compute deterministic cache key for ClickHouse schema & ORM migration snapshot."""
    ch_major_minor = parse_ch_major_minor(ch_version)
    orm_block = _uv_lock_package_block(repo_root / "uv.lock", ("infi-clickhouse-orm", "infi.clickhouse-orm"))
    paths = [
        repo_root / "infra" / "clickhouse" / "config.xml",
        repo_root / "showcase" / "scripts" / "live_posthog.sh",
        repo_root / "showcase" / "scripts" / "live_migrate_cache.py",
        *ch_migration_files(repo_root),
    ]
    extra = [
        "live-ch-v1",
        f"ch_major_minor={ch_major_minor}",
        f"orm_lock={orm_block}",
    ]
    return _hash_paths(repo_root, paths, extra)


def canonicalize_ddl(ddl: str, ch_db: str, kafka_prefix: str, kafka_broker: str) -> str:
    """Strip Atomic UUIDs and replace environment-specific DB/Kafka/Keeper identifiers with tokens."""
    out = _CREATE_UUID_RE.sub(r"\1", ddl.strip())
    out = _ZK_PATH_RE.sub(rf"'/clickhouse/tables/{TOKEN_CH_ZK}/\1'", out)
    if ch_db:
        # Substitute ch_db BEFORE kafka_prefix so `<ch_db>` containing `<worker>_` is never split.
        out = re.sub(rf"(?<![A-Za-z0-9_]){re.escape(ch_db)}(?![A-Za-z0-9_])", TOKEN_CH_DB, out)
    if kafka_broker:
        out = out.replace(kafka_broker, TOKEN_KAFKA_BROKER)
    if kafka_prefix:
        out = out.replace(kafka_prefix, TOKEN_KAFKA_PREFIX)
    return out


def instantiate_ddl(
    ddl: str,
    ch_db: str,
    kafka_prefix: str,
    kafka_broker: str,
    zk_prefix: str,
) -> str:
    """Rehydrate a canonicalized ClickHouse DDL statement for an isolated target database."""
    return (
        ddl.replace(TOKEN_CH_ZK, zk_prefix)
        .replace(TOKEN_CH_DB, ch_db)
        .replace(TOKEN_KAFKA_PREFIX, kafka_prefix)
        .replace(TOKEN_KAFKA_BROKER, kafka_broker)
    )


def _table_tier(engine: str) -> int:
    if engine in _VIEW_ENGINES:
        return 3
    if engine == "Dictionary":
        return 2
    if engine in _OVERLAY_ENGINES:
        return 1
    return 0


def _referenced_tables(row: dict, all_names: set[str], ch_db: str) -> set[str]:
    deps: set[str] = set()
    for dep in row.get("dependencies_table") or ():
        short = dep.split(".")[-1].strip("`")
        if short in all_names and short != row["name"]:
            deps.add(short)
    ddl = row.get("ddl") or ""
    db_patterns = (re.escape(ch_db), re.escape(TOKEN_CH_DB))
    for db_pat in db_patterns:
        if not db_pat:
            continue
        for m in re.finditer(rf"`?{db_pat}`?\.`?([A-Za-z0-9_]+)`?", ddl):
            cand = m.group(1)
            if cand in all_names and cand != row["name"]:
                deps.add(cand)
    # Dictionaries or MVs can reference bare table names in `TO tbl` / `FROM tbl` / `TABLE 'tbl'`.
    for m in re.finditer(r"\b(?:TO|FROM|JOIN|TABLE)\s+`?([A-Za-z0-9_]+)`?", ddl, re.IGNORECASE):
        cand = m.group(1)
        if cand in all_names and cand != row["name"]:
            deps.add(cand)
    return deps


def order_ddl_statements(rows: list[dict], ch_db: str) -> list[dict]:
    """Order ClickHouse objects: base tables -> Buffer/Distributed -> Dictionary -> Views/MVs."""
    by_tier: dict[int, list[dict]] = {0: [], 1: [], 2: [], 3: []}
    for row in rows:
        by_tier[_table_tier(row.get("engine", ""))].append(row)

    all_names = {r["name"] for r in rows}
    ordered: list[dict] = []
    emitted: set[str] = set()

    for tier in (0, 1, 2, 3):
        tier_rows = sorted(by_tier[tier], key=lambda r: r["name"])
        if tier == 0:
            ordered.extend(tier_rows)
            emitted.update(r["name"] for r in tier_rows)
            continue
        tier_names = {r["name"] for r in tier_rows}
        row_by_name = {r["name"]: r for r in tier_rows}
        deps_map: dict[str, set[str]] = {}
        rdeps: dict[str, list[str]] = collections.defaultdict(list)
        indegree: dict[str, int] = {}
        for r in tier_rows:
            deps = {d for d in _referenced_tables(r, all_names, ch_db) if d in tier_names and d not in emitted}
            deps_map[r["name"]] = deps
            indegree[r["name"]] = len(deps)
            for d in deps:
                rdeps[d].append(r["name"])

        ready = sorted(name for name, deg in indegree.items() if deg == 0)
        tier_done: list[str] = []
        while ready:
            cur = ready.pop(0)
            tier_done.append(cur)
            for nxt in sorted(rdeps.get(cur, ())):
                indegree[nxt] -= 1
                if indegree[nxt] == 0:
                    ready.append(nxt)
                    ready.sort()
        # Any cycle fallback preserves deterministic alphabetical order without dropping objects.
        if len(tier_done) < len(tier_rows):
            remaining = sorted(name for name in row_by_name if name not in set(tier_done))
            tier_done.extend(remaining)
        for name in tier_done:
            ordered.append(row_by_name[name])
            emitted.add(name)
    return ordered


def ch_http_query(
    http_url: str,
    sql: str,
    user: str = "default",
    password: str = "",
    database: str | None = None,
    body: bytes | None = None,
) -> bytes:
    """Execute a ClickHouse SQL statement or data load over HTTP."""
    params: dict[str, str] = {"query": sql}
    if database:
        params["database"] = database
    sep = "&" if "?" in http_url else "?"
    url = f"{http_url.rstrip('/')}{sep}{urllib.parse.urlencode(params)}"
    data = body if body is not None else b""
    req = urllib.request.Request(url, data=data, method="POST")
    if user:
        req.add_header("X-ClickHouse-User", user)
    if password:
        req.add_header("X-ClickHouse-Key", password)
    req.add_header("Content-Type", "text/plain; charset=utf-8")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"ClickHouse HTTP {exc.code} for `{sql[:120]}`: {detail}") from exc


def ch_http_json_rows(
    http_url: str,
    sql: str,
    user: str = "default",
    password: str = "",
) -> list[dict]:
    raw = ch_http_query(http_url, f"{sql} FORMAT JSON", user=user, password=password)
    return json.loads(raw.decode("utf-8")).get("data", [])


def select_ch_base(store_root: Path, repo_root: Path, ch_version: str) -> Path | None:
    """Select the newest verified ClickHouse schema snapshot whose applied migrations are a subset of disk."""
    if not store_root.is_dir():
        return None
    ch_major_minor = parse_ch_major_minor(ch_version)
    current_pairs = repo_ch_migrations(repo_root)
    runtime_tag = f"ch{ch_major_minor}"
    best: tuple[tuple[int, float], Path] | None = None
    for entry in store_root.iterdir():
        if not entry.is_dir() or not _KEY_RE.fullmatch(entry.name):
            continue
        gen_dir = resolve_verified_generation(
            store_root, CH_FORMAT_PREFIX, entry.name, CH_REQUIRED_FILES, expected_runtime_tag=runtime_tag
        )
        if gen_dir is None:
            continue
        try:
            meta = json.loads((gen_dir / "migrations.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        applied = meta.get("applied")
        if not isinstance(applied, list) or not applied:
            continue
        if not all(
            isinstance(row, list) and len(row) == 2 and (row[0], row[1]) in current_pairs
            for row in applied
        ):
            continue
        rank = (len(applied), gen_dir.stat().st_mtime)
        if best is None or rank > best[0]:
            best = (rank, gen_dir)
    return best[1] if best else None


def capture_ch_snapshot(
    snapshot_root: Path,
    repo_root: Path,
    key: str,
    ch_version: str,
    http_url: str,
    ch_db: str,
    kafka_prefix: str,
    kafka_broker: str,
    user: str,
    password: str,
) -> Path:
    """Export canonicalized ClickHouse DDL, applied ORM migrations, and seeded reference rows."""
    ch_major_minor = parse_ch_major_minor(ch_version)
    db_literal = ch_db.replace("'", "''")
    raw_tables = ch_http_json_rows(
        http_url,
        (
            "SELECT name, engine, create_table_query, dependencies_table, toUInt64(ifNull(total_rows, 0)) AS total_rows "
            f"FROM system.tables WHERE database = '{db_literal}' AND is_temporary = 0 ORDER BY name"
        ),
        user=user,
        password=password,
    )
    if not raw_tables:
        raise RuntimeError(f"No ClickHouse tables found in database {ch_db}")

    ddl_rows = [
        {
            "name": row["name"],
            "engine": row["engine"],
            "ddl": row["create_table_query"],
            "dependencies_table": row.get("dependencies_table") or [],
        }
        for row in raw_tables
        if row.get("create_table_query")
    ]
    ordered = order_ddl_statements(ddl_rows, ch_db)
    canonical_statements = [
        {
            "name": row["name"],
            "engine": row["engine"],
            "ddl": canonicalize_ddl(row["ddl"], ch_db, kafka_prefix, kafka_broker),
        }
        for row in ordered
    ]

    mig_jsonl = (
        ch_http_query(
            http_url,
            f"SELECT * FROM `{ch_db}`.`infi_clickhouse_orm_migrations` ORDER BY package_name, module_name FORMAT JSONEachRow",
            user=user,
            password=password,
        )
        .decode("utf-8")
        .strip()
    )
    if not mig_jsonl:
        raise RuntimeError(f"No rows in {ch_db}.infi_clickhouse_orm_migrations")
    applied_pairs = []
    for line in mig_jsonl.splitlines():
        rec = json.loads(line)
        applied_pairs.append([rec["package_name"], rec["module_name"]])

    seed_tables: dict[str, str] = {}
    for row in raw_tables:
        tname = row["name"]
        engine = row.get("engine", "")
        total_rows = int(row.get("total_rows") or 0)
        if (
            tname in {"infi_clickhouse_orm_migrations", "infi_clickhouse_orm_migrations_distributed"}
            or engine in _VIEW_ENGINES
            or engine in _OVERLAY_ENGINES
            or engine in {"Kafka", "Dictionary"}
            or total_rows <= 0
            or total_rows > MAX_SEED_TABLE_ROWS
        ):
            continue
        rows_txt = (
            ch_http_query(
                http_url,
                f"SELECT * FROM `{ch_db}`.`{tname}` FORMAT JSONEachRow",
                user=user,
                password=password,
            )
            .decode("utf-8")
            .strip()
        )
        if rows_txt:
            seed_tables[tname] = rows_txt

    store_root = snapshot_root / "ch-v1"
    with file_lock(store_root / f"{key}.lock"):
        existing = resolve_verified_generation(
            store_root, CH_FORMAT_PREFIX, key, CH_REQUIRED_FILES, expected_runtime_tag=f"ch{ch_major_minor}"
        )
        if existing is not None:
            return existing
        files = {
            "ddl.json": json.dumps(
                {
                    "database_ddl": f"CREATE DATABASE IF NOT EXISTS {TOKEN_CH_DB}",
                    "statements": canonical_statements,
                },
                sort_keys=True,
            ).encode("utf-8"),
            "migrations.json": json.dumps(
                {
                    "ch_major_minor": ch_major_minor,
                    "applied": applied_pairs,
                    "applied_jsonl": mig_jsonl,
                },
                sort_keys=True,
            ).encode("utf-8"),
            "seed_rows.json": json.dumps(seed_tables, sort_keys=True).encode("utf-8"),
        }
        return publish_generation(store_root, CH_FORMAT_PREFIX, key, f"ch{ch_major_minor}", files)


def restore_ch_snapshot(
    snapshot_root: Path,
    repo_root: Path,
    key: str,
    ch_version: str,
    http_url: str,
    ch_db: str,
    kafka_prefix: str,
    kafka_broker: str,
    user: str,
    password: str,
    exact_only: bool = False,
) -> str:
    """Restore an exact or compatible subset ClickHouse snapshot; return ``exact`` or ``base``."""
    ch_major_minor = parse_ch_major_minor(ch_version)
    store_root = snapshot_root / "ch-v1"
    gen_dir = resolve_verified_generation(
        store_root, CH_FORMAT_PREFIX, key, CH_REQUIRED_FILES, expected_runtime_tag=f"ch{ch_major_minor}"
    )
    mode = "exact"
    if gen_dir is None:
        if exact_only:
            raise FileNotFoundError(f"No verified exact ClickHouse snapshot for {key}")
        gen_dir = select_ch_base(store_root, repo_root, ch_version)
        if gen_dir is None:
            raise FileNotFoundError(f"No compatible ClickHouse snapshot under {store_root}")
        mode = "base"

    ddl_doc = json.loads((gen_dir / "ddl.json").read_text(encoding="utf-8"))
    mig_doc = json.loads((gen_dir / "migrations.json").read_text(encoding="utf-8"))
    seed_doc = json.loads((gen_dir / "seed_rows.json").read_text(encoding="utf-8"))

    zk_prefix = f"{ch_db}_{uuid.uuid4().hex[:8]}"
    ch_http_query(http_url, "SYSTEM FLUSH LOGS", user=user, password=password)
    ch_http_query(http_url, f"DROP DATABASE IF EXISTS `{ch_db}` SYNC", user=user, password=password)
    ch_http_query(
        http_url,
        instantiate_ddl(ddl_doc["database_ddl"], ch_db, kafka_prefix, kafka_broker, zk_prefix),
        user=user,
        password=password,
    )
    for stmt in ddl_doc["statements"]:
        sql = instantiate_ddl(stmt["ddl"], ch_db, kafka_prefix, kafka_broker, zk_prefix)
        ch_http_query(http_url, sql, user=user, password=password, database=ch_db)

    applied_jsonl = mig_doc["applied_jsonl"].strip()
    if applied_jsonl:
        ch_http_query(
            http_url,
            f"INSERT INTO `{ch_db}`.`infi_clickhouse_orm_migrations` FORMAT JSONEachRow",
            user=user,
            password=password,
            database=ch_db,
            body=(applied_jsonl + "\n").encode("utf-8"),
        )
    for table_name, rows_jsonl in sorted(seed_doc.items()):
        if not rows_jsonl.strip():
            continue
        ch_http_query(
            http_url,
            f"INSERT INTO `{ch_db}`.`{table_name}` FORMAT JSONEachRow",
            user=user,
            password=password,
            database=ch_db,
            body=(rows_jsonl.strip() + "\n").encode("utf-8"),
        )
    return mode


# ---------------------------------------------------------------------------
# CLI entrypoint
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("routed-apps")
    p.add_argument("--repo", required=True, type=Path)

    p = sub.add_parser("pg-key")
    p.add_argument("--repo", required=True, type=Path)
    p.add_argument("--template-key", required=True)
    p.add_argument("--pg-major", required=True)

    p = sub.add_parser("pg-verify")
    p.add_argument("--snapshot-root", required=True, type=Path)
    p.add_argument("--key", required=True)
    p.add_argument("--pg-major", required=True)

    p = sub.add_parser("pg-base")
    p.add_argument("--snapshot-root", required=True, type=Path)
    p.add_argument("--repo", required=True, type=Path)
    p.add_argument("--template-key", required=True)
    p.add_argument("--pg-major", required=True)

    p = sub.add_parser("pg-publish")
    p.add_argument("--snapshot-root", required=True, type=Path)
    p.add_argument("--repo", required=True, type=Path)
    p.add_argument("--key", required=True)
    p.add_argument("--pg-major", required=True)
    p.add_argument("--template-key", required=True)
    p.add_argument("--dump-file", required=True, type=Path)
    p.add_argument("--applied-file", required=True, type=Path)

    p = sub.add_parser("ch-key")
    p.add_argument("--repo", required=True, type=Path)
    p.add_argument("--ch-version", required=True)

    for name in ("ch-capture", "ch-restore"):
        p = sub.add_parser(name)
        p.add_argument("--snapshot-root", required=True, type=Path)
        p.add_argument("--repo", required=True, type=Path)
        p.add_argument("--key", required=True)
        p.add_argument("--ch-version", required=True)
        p.add_argument("--http-url", required=True)
        p.add_argument("--ch-db", required=True)
        p.add_argument("--kafka-prefix", required=True)
        p.add_argument("--kafka-broker", required=True)
        p.add_argument("--user", default="default")
        p.add_argument("--password", default="")
        if name == "ch-restore":
            p.add_argument("--exact-only", action="store_true")

    p = sub.add_parser("verify")
    p.add_argument("snapshot_root", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.cmd == "routed-apps":
        print(",".join(f"'{app}'" for app in routed_apps(args.repo.resolve())))
        return 0

    if args.cmd == "pg-key":
        print(compute_pg_key(args.repo.resolve(), args.template_key, args.pg_major))
        return 0

    if args.cmd == "pg-verify":
        gen_dir = resolve_verified_generation(
            args.snapshot_root.resolve() / "live-v1",
            PG_FORMAT_PREFIX,
            args.key,
            PG_REQUIRED_FILES,
            expected_runtime_tag=f"pg{args.pg_major}",
        )
        if gen_dir is None:
            return 1
        print(gen_dir)
        return 0

    if args.cmd == "pg-base":
        gen_dir = select_pg_base(
            args.snapshot_root.resolve() / "live-v1",
            args.repo.resolve(),
            args.template_key,
            args.pg_major,
        )
        if gen_dir is None:
            return 1
        print(gen_dir)
        return 0

    if args.cmd == "pg-publish":
        store_root = args.snapshot_root.resolve() / "live-v1"
        applied = [
            line.split("\t", 1)
            for line in args.applied_file.read_text(encoding="utf-8").splitlines()
            if "\t" in line
        ]
        if not applied:
            raise ValueError("Refusing to publish empty django_migrations list")
        # Dedicated lock suffix so callers holding `<key>.lock` / `<key>.migrate.lock` never self-deadlock.
        with file_lock(store_root / f"{args.key}.publish.lock"):
            existing = resolve_verified_generation(
                store_root,
                PG_FORMAT_PREFIX,
                args.key,
                PG_REQUIRED_FILES,
                expected_runtime_tag=f"pg{args.pg_major}",
            )
            if existing is not None:
                print(existing)
                return 0
            files = {
                "live-postgres.dump": args.dump_file.read_bytes(),
                "live-migrations.json": json.dumps(
                    {
                        "template_key": args.template_key,
                        "routed_apps": routed_apps(args.repo.resolve()),
                        "applied": applied,
                    },
                    sort_keys=True,
                ).encode("utf-8"),
            }
            print(publish_generation(store_root, PG_FORMAT_PREFIX, args.key, f"pg{args.pg_major}", files))
        return 0

    if args.cmd == "ch-key":
        print(compute_ch_key(args.repo.resolve(), args.ch_version))
        return 0

    if args.cmd == "ch-capture":
        gen_dir = capture_ch_snapshot(
            args.snapshot_root.resolve(),
            args.repo.resolve(),
            args.key,
            args.ch_version,
            args.http_url,
            args.ch_db,
            args.kafka_prefix,
            args.kafka_broker,
            args.user,
            args.password,
        )
        print(gen_dir)
        return 0

    if args.cmd == "ch-restore":
        try:
            mode = restore_ch_snapshot(
                args.snapshot_root.resolve(),
                args.repo.resolve(),
                args.key,
                args.ch_version,
                args.http_url,
                args.ch_db,
                args.kafka_prefix,
                args.kafka_broker,
                args.user,
                args.password,
                exact_only=args.exact_only,
            )
        except Exception as exc:
            print(f"ch-restore miss/error: {exc}", file=sys.stderr)
            return 1
        print(mode)
        return 0

    if args.cmd == "verify":
        root = args.snapshot_root.resolve()
        live_ok, live_errs = verify_store(root / "live-v1", PG_FORMAT_PREFIX, PG_REQUIRED_FILES)
        ch_ok, ch_errs = verify_store(root / "ch-v1", CH_FORMAT_PREFIX, CH_REQUIRED_FILES)
        errors = live_errs + ch_errs
        eligible = (not errors) and (live_ok or ch_ok)
        github_output = os.environ.get("GITHUB_OUTPUT")
        if github_output:
            with open(github_output, "a", encoding="utf-8") as out:
                out.write(f"eligible={'true' if eligible else 'false'}\n")
        if errors:
            for err in errors:
                print(f"Live migration snapshot refused: {err}", file=sys.stderr)
            return 1
        return 0

    return 2


if __name__ == "__main__":
    sys.exit(main())
