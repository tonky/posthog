"""Product lint runner."""

from __future__ import annotations

import os
import concurrent.futures
from pathlib import Path

import click

from .baseline import check_baseline
from .checks import CHECKS, CheckContext, ProductYamlOwnersCheck, is_isolated_product, validate_tach_toml
from .paths import ISOLATION_BASELINE, PRODUCTS_DIR, REPO_ROOT, TACH_TOML, backend_product_dirs, load_structure

_IN_GH_ACTIONS = os.environ.get("GITHUB_ACTIONS") == "true"


def _gh_annotation(
    level: str,
    product: str,
    check_label: str,
    message: str,
    file: str | None = None,
    sink: list[str] | None = None,
) -> None:
    if _IN_GH_ACTIONS:
        file_part = f" file={file}" if file else ""
        msg = f"::{level}{file_part} title=product:lint ({product} / {check_label})::{message}"
        if sink is not None:
            sink.append(msg)
        else:
            click.echo(msg)


def lint_product(
    name: str,
    verbose: bool = True,
    detailed: bool = False,
    structure: dict | None = None,
    sink: list[str] | None = None,
) -> list[str]:
    """
    Lint a product's structure. Returns list of issues found.

    Runs in two modes based on whether the product has backend/facade/contracts.py:
      strict  — isolated product, all structure rules enforced
      lenient — legacy product, subset of rules enforced (see product_structure.yaml)

    Set detailed=True (single-product run) for richer isolation progress output.
    Pass structure= to avoid re-parsing product_structure.yaml on every call (useful in --all mode).
    Pass sink= to collect console output lines instead of printing immediately (used for parallel execution).
    """

    def _log(msg: str) -> None:
        if sink is not None:
            sink.append(msg)
        else:
            click.echo(msg)

    product_dir = PRODUCTS_DIR / name
    backend_dir = product_dir / "backend"

    if not product_dir.exists():
        raise click.ClickException(f"Product '{name}' not found at {product_dir}")

    isolated = is_isolated_product(backend_dir)
    mode = "strict" if isolated else "lenient"

    if verbose:
        _log(f"  mode: {mode}" + (" (has backend/facade/contracts.py)" if isolated else " (legacy)"))

    ctx = CheckContext(
        name=name,
        product_dir=product_dir,
        backend_dir=backend_dir,
        is_isolated=isolated,
        structure=structure or load_structure(),
        detailed=detailed,
    )

    issues: list[str] = []
    for check in CHECKS:
        if not check.should_run(ctx):
            continue
        if verbose:
            _log(f"  {check.label}...")
        result = check.run(ctx)
        if result.skip:
            continue
        if verbose:
            for line in result.lines:
                _log(f"    {line}")
        issues.extend(result.issues)
        for issue in result.issues:
            _gh_annotation("error", name, check.label, issue, file=result.file, sink=sink)
        for warning in result.warnings:
            _gh_annotation("warning", name, check.label, warning, file=result.file, sink=sink)

    return issues


def _lint_tach_toml() -> list[str]:
    """Validate tach.toml structure and referential integrity."""
    if not TACH_TOML.exists():
        return []
    issues = validate_tach_toml(TACH_TOML.read_text(), PRODUCTS_DIR)
    for issue in issues:
        _gh_annotation("error", "tach", "tach.toml", issue, file="tach.toml")
    return issues


def _lint_product_worker(name: str, detailed: bool, structure: dict) -> tuple[str, list[str], list[str]]:
    sink: list[str] = []
    issues = lint_product(name, verbose=True, detailed=detailed, structure=structure, sink=sink)
    return name, issues, sink


def detect_changed_product_targets(
    against: str | None = None,
) -> tuple[list[str], bool, bool]:
    """Inspect git diff to find changed products, tach.toml, and isolation baseline.

    Returns:
        (changed_product_names, tach_changed, baseline_changed)
    """
    from hogli_commands.change_detection import changed_files

    files = changed_files(against=against)
    changed_products: set[str] = set()
    tach_changed = False
    baseline_changed = False

    for file_path in files:
        if file_path == "tach.toml":
            tach_changed = True
        elif file_path == "products/isolation_baseline.txt" or file_path.startswith("products/isolation_baseline"):
            baseline_changed = True

        parts = Path(file_path).parts
        if len(parts) >= 2 and parts[0] == "products":
            product_name = parts[1]
            product_dir = PRODUCTS_DIR / product_name
            if (
                product_dir.is_dir()
                and not product_name.startswith((".", "_"))
                and (product_dir / "__init__.py").exists()
            ):
                changed_products.add(product_name)

    return sorted(changed_products), tach_changed, baseline_changed


def lint_changed_products(
    names: list[str],
    check_tach: bool = True,
    check_baseline: bool = True,
    structure: dict | None = None,
) -> None:
    """Lint only changed products and modified global isolation configurations."""
    if not names and not check_tach and not check_baseline:
        click.echo("✓ No products or isolation configs modified (use --all to lint all products)")
        return

    scope = f"{len(names)} changed product(s)" if names else "global isolation configuration"
    click.echo(f"Linting {scope}" + (f": {', '.join(names)}\n" if names else "\n"))

    structure = structure or load_structure()
    failed: list[str] = []

    for name in names:
        click.echo(f"─ {name}")
        issues = lint_product(name, verbose=True, detailed=True, structure=structure)
        if issues:
            failed.append(name)
        click.echo("")

    tach_issues: list[str] = []
    if check_tach:
        click.echo("─ tach.toml")
        tach_issues = _lint_tach_toml()
        if tach_issues:
            click.echo(f"  ✗ {len(tach_issues)} issue(s)")
            for issue in tach_issues:
                click.echo(f"    → {issue}")
        else:
            click.echo("  ✓ ok")
        click.echo("")

    baseline_issues: list[str] = []
    if check_baseline:
        click.echo("─ isolation baseline")
        baseline_issues = check_baseline()
        if baseline_issues:
            click.echo(f"  ✗ {len(baseline_issues)} issue(s)")
            for issue in baseline_issues:
                click.echo(f"    → {issue}")
                _gh_annotation(
                    "error",
                    "products",
                    "isolation baseline",
                    issue,
                    file=str(ISOLATION_BASELINE.relative_to(REPO_ROOT)),
                )
        else:
            click.echo("  ✓ ok")
        click.echo("")

    if failed or tach_issues or baseline_issues:
        if failed:
            click.echo(f"✗ {len(failed)} product(s) failed: {', '.join(failed)}")
        if tach_issues:
            click.echo(f"✗ {len(tach_issues)} tach.toml issue(s)")
        if baseline_issues:
            click.echo(f"✗ {len(baseline_issues)} isolation baseline issue(s)")
        raise SystemExit(1)

    click.echo(f"✓ All {len(names)} changed product(s) passed" if names else "✓ Global isolation checks passed")


def lint_all_products(parallel: bool = True, max_workers: int | None = None) -> None:
    product_dirs = backend_product_dirs()

    strict = [d.name for d in product_dirs if is_isolated_product(d / "backend")]
    lenient = [d.name for d in product_dirs if not is_isolated_product(d / "backend")]

    click.echo(f"Linting {len(product_dirs)} products ({len(strict)} strict, {len(lenient)} lenient)")
    click.echo(
        "Checks: required root files, package.json scripts (presence + content), misplaced files (strict), "
        "file/folder conflicts, tach boundaries (+ interfaces for strict), isolation progress (lenient), "
        "isolation baseline\n"
    )

    structure = load_structure()
    failed: list[str] = []

    if parallel and len(product_dirs) > 1:
        workers = max_workers or min(16, os.cpu_count() or 4)
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
            futures = [executor.submit(_lint_product_worker, p.name, False, structure) for p in product_dirs]
            for future in futures:
                name, issues, sink = future.result()
                click.echo(f"─ {name}")
                for line in sink:
                    click.echo(line)
                if issues:
                    failed.append(name)
                click.echo("")
    else:
        for product_dir in product_dirs:
            click.echo(f"─ {product_dir.name}")
            issues = lint_product(product_dir.name, verbose=True, detailed=False, structure=structure)
            if issues:
                failed.append(product_dir.name)
            click.echo("")

    click.echo("─ tach.toml")
    tach_issues = _lint_tach_toml()
    if tach_issues:
        click.echo(f"  ✗ {len(tach_issues)} issue(s)")
        for issue in tach_issues:
            click.echo(f"    → {issue}")
    else:
        click.echo("  ✓ ok")
    click.echo("")

    click.echo("─ isolation baseline")
    baseline_issues = check_baseline()
    if baseline_issues:
        click.echo(f"  ✗ {len(baseline_issues)} issue(s)")
        for issue in baseline_issues:
            click.echo(f"    → {issue}")
            _gh_annotation(
                "error", "products", "isolation baseline", issue, file=str(ISOLATION_BASELINE.relative_to(REPO_ROOT))
            )
    else:
        click.echo("  ✓ ok")
    click.echo("")

    if failed or tach_issues or baseline_issues:
        if failed:
            click.echo(f"✗ {len(failed)} product(s) failed: {', '.join(failed)}")
        if tach_issues:
            click.echo(f"✗ {len(tach_issues)} tach.toml issue(s)")
        if baseline_issues:
            click.echo(f"✗ {len(baseline_issues)} isolation baseline issue(s)")
        raise SystemExit(1)

    click.echo(f"✓ All {len(product_dirs)} products passed")


def lint_owners(names: list[str] | None = None) -> None:
    """Validate product.yaml ``owners:`` against repo-collaborator GitHub teams.

    With ``names`` empty/None, sweeps every product (local convenience). In CI
    the call site passes the list of products whose product.yaml actually
    changed, so pre-existing rot elsewhere doesn't block unrelated PRs.

    Separated from ``lint_all_products`` because it makes a GitHub API call —
    wired into CI behind a paths filter so it only runs when a product.yaml
    changes.
    """
    if names:
        targets: list[Path] = []
        for name in names:
            d = PRODUCTS_DIR / name
            if not d.is_dir():
                click.echo(f"⚠ skipping '{name}': not a product directory")
                continue
            targets.append(d)
        # If the caller passed names but none resolved, treat it as an error —
        # otherwise an unexpected slug from CI's sed/xargs pipeline would slip
        # through as a silent green ("✓ All 0 product owners are valid").
        if not targets:
            click.echo("✗ None of the provided names matched a product directory — nothing validated")
            raise SystemExit(1)
    else:
        targets = sorted(
            d
            for d in PRODUCTS_DIR.iterdir()
            if d.is_dir() and not d.name.startswith((".", "_")) and (d / "__init__.py").exists()
        )

    check = ProductYamlOwnersCheck()
    structure = load_structure()
    failed: list[str] = []

    scope = "all products" if not names else f"{len(targets)} changed product(s)"
    click.echo(f"Validating product.yaml owners across {scope} against PostHog/posthog teams\n")

    for product_dir in targets:
        ctx = CheckContext(
            name=product_dir.name,
            product_dir=product_dir,
            backend_dir=product_dir / "backend",
            is_isolated=is_isolated_product(product_dir / "backend"),
            structure=structure,
            detailed=False,
        )
        result = check.run(ctx)
        if result.skip:
            continue
        if result.issues:
            failed.append(product_dir.name)
            click.echo(f"─ {product_dir.name}")
            for line in result.lines:
                click.echo(f"    {line}")
            for issue in result.issues:
                _gh_annotation("error", product_dir.name, check.label, issue, file=result.file)

    click.echo("")
    if failed:
        click.echo(f"✗ {len(failed)} product(s) failed owner validation: {', '.join(failed)}")
        raise SystemExit(1)

    click.echo(f"✓ All {len(targets)} product owners are valid PostHog/posthog teams")
