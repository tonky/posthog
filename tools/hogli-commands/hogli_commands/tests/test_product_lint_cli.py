"""Unit tests for product:lint CLI, auto-scoping, and changed product detection."""

from __future__ import annotations

from pathlib import Path

from unittest.mock import patch

from click.testing import CliRunner
from hogli_commands.product.cli import cmd_lint
from hogli_commands.product.lint import detect_changed_product_targets


def test_detect_changed_product_targets_filters_products(tmp_path: Path) -> None:
    changed = [
        "products/access_control/backend/facade/api.py",
        "products/not_a_product_dir/foo.py",
        "posthog/api/user.py",
        "tach.toml",
        "products/isolation_baseline.txt",
    ]
    with patch("hogli_commands.change_detection.changed_files", return_value=changed):
        products, tach_changed, baseline_changed = detect_changed_product_targets()
        assert "access_control" in products
        assert "not_a_product_dir" not in products
        assert tach_changed is True
        assert baseline_changed is True


def test_detect_changed_product_targets_empty() -> None:
    changed = [
        "posthog/api/user.py",
        "frontend/src/index.ts",
    ]
    with patch("hogli_commands.change_detection.changed_files", return_value=changed):
        products, tach_changed, baseline_changed = detect_changed_product_targets()
        assert products == []
        assert tach_changed is False
        assert baseline_changed is False


def test_cmd_lint_no_args_nothing_changed() -> None:
    runner = CliRunner()
    with patch("hogli_commands.product.cli.detect_changed_product_targets", return_value=([], False, False)):
        result = runner.invoke(cmd_lint, [])
        assert result.exit_code == 0
        assert "No products or isolation configs modified" in result.output


def test_cmd_lint_changed_flag_invokes_changed_products() -> None:
    runner = CliRunner()
    with (
        patch(
            "hogli_commands.product.cli.detect_changed_product_targets",
            return_value=(["access_control"], False, False),
        ),
        patch("hogli_commands.product.cli.lint_changed_products") as mock_lint,
    ):
        result = runner.invoke(cmd_lint, ["--changed"])
        assert result.exit_code == 0
        mock_lint.assert_called_once_with(["access_control"], check_tach=False, check_baseline=False)


def test_cmd_lint_specific_product() -> None:
    runner = CliRunner()
    with patch("hogli_commands.product.cli.lint_product", return_value=[]) as mock_lint:
        result = runner.invoke(cmd_lint, ["access_control"])
        assert result.exit_code == 0
        assert "✓ All checks passed" in result.output
        mock_lint.assert_called_once_with("access_control", verbose=True, detailed=True)


def test_cmd_lint_all_disallows_combining_with_name() -> None:
    runner = CliRunner()
    result = runner.invoke(cmd_lint, ["--all", "access_control"])
    assert result.exit_code != 0
    assert "--all does not combine with specific product names or paths" in result.output


def test_cmd_lint_resolves_file_paths() -> None:
    runner = CliRunner()
    with patch("hogli_commands.product.cli.lint_product", return_value=[]) as mock_lint:
        result = runner.invoke(cmd_lint, ["products/access_control/backend/facade/api.py"])
        assert result.exit_code == 0
        mock_lint.assert_called_once_with("access_control", verbose=True, detailed=True)


def test_cmd_lint_multiple_products() -> None:
    runner = CliRunner()
    with patch("hogli_commands.product.cli.lint_changed_products") as mock_lint:
        result = runner.invoke(cmd_lint, ["access_control", "products/visual_review/product.yaml"])
        assert result.exit_code == 0
        mock_lint.assert_called_once_with(["access_control", "visual_review"], check_tach=False, check_baseline=False)
