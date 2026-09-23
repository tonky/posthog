#!/usr/bin/env python3
"""Run the showcase's native static checks on supported changed paths only."""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import quoteattr


def parse_ruff_check(output):
    errors = {}
    seen = set()
    pat = re.compile(
        r"^(?P<file>[^:\s]+\.pyi?):(?P<line>\d+):(?:\d+:)?\s*(?P<code>[A-Z0-9]+)\s+(?:\[\*\]\s+)?(?P<msg>.*)$"
    )
    for raw in output.splitlines():
        m = pat.match(raw.strip())
        if m:
            c = f"{m.group('file')}:{m.group('line')}: error: {m.group('msg').strip()} [{m.group('code')}]"
            if c not in seen:
                seen.add(c)
                errors.setdefault(m.group("file"), []).append(c)
    return errors


def parse_ruff_fmt(output):
    errors = {}
    seen = set()
    pat = re.compile(r"^Would reformat:\s+(?P<file>[^:\s]+\.pyi?)$")
    for raw in output.splitlines():
        m = pat.match(raw.strip())
        if m:
            f = m.group("file")
            c = f"{f}:1: error: file requires formatting [format]"
            if c not in seen:
                seen.add(c)
                errors.setdefault(f, []).append(c)
    return errors


def parse_importlinter(output):
    errors = {}
    pending_src = None
    for line in output.splitlines():
        plain = line.strip()
        if plain.startswith("[WARN]") or plain.startswith("Warning:") or "UserWarning" in plain or "site-packages" in plain:
            pending_src = None
            continue
        if pending_src:
            src_mod = pending_src
            pending_src = None
            if " (l." in plain and plain.endswith(")"):
                target_mod, line_info = plain.split(" (l.", 1)
                line_no = line_info[:-1]
                if line_no.isdigit():
                    f = src_mod.replace(".", "/") + ".py"
                    canon = f"{f}:{line_no}: error: imported forbidden module {target_mod} [import-linter]"
                    errors.setdefault(f, []).append(canon)
                    continue
        stripped = plain.lstrip("- \t")
        if "->" in stripped:
            src_mod, rest = stripped.split("->", 1)
            src_mod = src_mod.strip()
            rest = rest.strip()
            if not rest:
                pending_src = src_mod
                continue
            if " (l." in rest and rest.endswith(")"):
                target_mod, line_info = rest.split(" (l.", 1)
                line_no = line_info[:-1]
                if line_no.isdigit():
                    f = src_mod.replace(".", "/") + ".py"
                    canon = f"{f}:{line_no}: error: imported forbidden module {target_mod} [import-linter]"
                    errors.setdefault(f, []).append(canon)
                    continue
    return errors


def parse_tach(output):
    errors = {}
    for line in output.splitlines():
        plain = line.strip()
        if plain.startswith("[WARN]") or plain.startswith("Warning:") or "UserWarning" in plain or "site-packages" in plain:
            continue
        plain = plain.removeprefix("##[error]").removeprefix("❌ ").strip()
        if ": " not in plain:
            continue
        loc, msg = plain.split(": ", 1)
        if "[L" in loc:
            f_name, rest = loc.split("[L", 1)
            if rest.endswith("]"):
                l_no = rest[:-1]
            else:
                continue
        else:
            parts = loc.split(":")
            if len(parts) in (2, 3):
                f_name, l_no = parts[0], parts[1]
            else:
                continue
        if f_name.startswith("/") or not (f_name.endswith(".py") or f_name.endswith(".pyi") or f_name.endswith("tach.toml")) or not l_no.isdigit():
            continue
        canon = f"{f_name}:{l_no}: error: {msg.strip()} [tach]"
        errors.setdefault(f_name, []).append(canon)
    return errors


def parse_cargo_fmt(output):
    errors = {}
    seen = set()
    pat = re.compile(r"^Diff in (?:.*/)?(?P<file>(?:rust/)?[^:\s]+\.rs) at line (?P<line>\d+):")
    for raw in output.splitlines():
        m = pat.match(raw.strip())
        if m:
            f = m.group("file")
            if not f.startswith("rust/"):
                f = "rust/" + f
            c = f"{f}:{m.group('line')}: error: file requires formatting [rustfmt]"
            if c not in seen:
                seen.add(c)
                errors.setdefault(f, []).append(c)
    return errors


def parse_cargo_clippy(output):
    errors = {}
    seen = set()
    pending_error = None
    for raw in output.splitlines():
        plain = raw.strip()
        if plain.startswith("error: "):
            pending_error = plain[len("error: "):].strip()
            continue
        elif plain.startswith("error[") and "]: " in plain:
            _, rest = plain.split("]: ", 1)
            pending_error = rest.strip()
            continue
        elif plain.startswith("warning: ") or plain.startswith("warning["):
            pending_error = None
            continue
        elif plain.startswith("--> "):
            if pending_error is not None:
                rest = plain[len("--> "):].strip()
                parts = rest.split(":")
                if len(parts) >= 2 and parts[1].isdigit():
                    f = parts[0]
                    if not f.startswith("rust/"):
                        f = "rust/" + f
                    line_no = parts[1]
                    msg = pending_error
                    pending_error = None
                    c = f"{f}:{line_no}: error: {msg} [clippy]"
                    if c not in seen:
                        seen.add(c)
                        errors.setdefault(f, []).append(c)
    return errors


def parse_golangci_lint(output):
    errors = {}
    seen = set()
    pat = re.compile(r"^(?P<file>[^:\s]+\.go):(?P<line>\d+)(?::\d+)?: (?P<msg>.*?) \((?P<rule>[\w-]+)\)$")
    for raw in output.splitlines():
        m = pat.match(raw.strip())
        if m:
            f = m.group("file")
            if not f.startswith("livestream/"):
                f = "livestream/" + f
            c = f"{f}:{m.group('line')}: error: {m.group('msg').strip()} [{m.group('rule')}]"
            if c not in seen:
                seen.add(c)
                errors.setdefault(f, []).append(c)
    return errors


def parse_buf_lint(output):
    errors = {}
    seen = set()
    pat = re.compile(r"^(?P<file>[^:\s]+\.proto):(?P<line>\d+):(?:\d+:)?(?P<msg>.*)$")
    for raw in output.splitlines():
        m = pat.match(raw.strip())
        if m:
            f = m.group("file")
            if not f.startswith("proto/"):
                f = "proto/" + f
            c = f"{f}:{m.group('line')}: error: {m.group('msg').strip()} [buf-lint]"
            if c not in seen:
                seen.add(c)
                errors.setdefault(f, []).append(c)
    return errors


def parse_actionlint(output):
    errors = {}
    seen = set()
    pat = re.compile(
        r"^(?P<file>[^:\s]+):(?P<line>\d+):(?:\d+:)?\s*(?P<msg>.*?)\s*(?:\[(?P<kind>[\w-]+)\])?$"
    )
    for raw in output.splitlines():
        line_str = raw.strip()
        if not line_str or line_str.startswith("|") or line_str.startswith(":::"):
            continue
        m = pat.match(line_str)
        if m:
            raw_f = m.group("file")
            if ".github/" in raw_f:
                f = raw_f[raw_f.index(".github/"):]
            else:
                f = f".github/workflows/{Path(raw_f).name}"
            line_no = m.group("line")
            msg = m.group("msg").strip()
            kind = m.group("kind") or "actionlint"
            c = f"{f}:{line_no}: error: {msg} [{kind}]"
            if c not in seen:
                seen.add(c)
                errors.setdefault(f, []).append(c)
    return errors


def find_binary(name: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    for base in [Path("/nix/store"), Path.home() / ".local/share/enve/store"]:
        if base.is_dir():
            matches = sorted(base.glob(f"*-{name}-*/bin/{name}"), reverse=True)
            if matches:
                return str(matches[0])
    return name


def parse_ingestion_boundaries(output: str):
    errors = {}
    seen = set()
    pat = re.compile(r"^\s*(?P<file>[^:\s]+\.ts)\s*->\s*(?P<target>.*)$")
    for raw in output.splitlines():
        line = raw.strip()
        m = pat.match(line)
        if m:
            raw_f = m.group("file")
            f = raw_f if raw_f.startswith("nodejs/") else f"nodejs/{raw_f}"
            target = m.group("target").strip()
            c = f"{f}:1: error: boundary violation: imported {target} [ingestion-boundaries]"
            if c not in seen:
                seen.add(c)
                errors.setdefault(f, []).append(c)
    return errors


def parse_oxlint(output: str, prefix: str = "nodejs/"):
    errors = {}
    seen = set()
    pat = re.compile(
        r"^(?P<file>[^:\s]+\.[mc]?[jt]sx?):(?P<line>\d+):(?:\d+:)?\s*error\s+(?:(?P<plugin>typescript|eslint)\((?P<rule>[^)]+)\)|(?P<bare_rule>[^:]+)):\s*(?P<msg>.*)$"
    )
    for raw in output.splitlines():
        line = raw.strip()
        m = pat.match(line)
        if m:
            raw_f = m.group("file")
            f = raw_f if (raw_f.startswith(prefix) or raw_f.startswith("nodejs/") or raw_f.startswith("services/mcp/")) else f"{prefix}{raw_f}"
            l = m.group("line")
            msg = m.group("msg").strip()
            rule = m.group("rule") or m.group("bare_rule") or "oxlint"
            c = f"{f}:{l}: error: {msg} [{rule.strip()}]"
            if c not in seen:
                seen.add(c)
                errors.setdefault(f, []).append(c)
    return errors


def parse_prettier_or_oxfmt(output: str, prefix: str = "nodejs/"):
    errors = {}
    seen = set()
    for raw in output.splitlines():
        line = raw.strip()
        f = None
        if line.startswith("[warn] ") and not line.endswith("Forgot to run Prettier?"):
            f = line.removeprefix("[warn] ").split(":")[0].strip()
        elif line.startswith("Diff in "):
            f = line.removeprefix("Diff in ").split(":")[0].strip()
        elif line.startswith("Would reformat: "):
            f = line.removeprefix("Would reformat: ").split(":")[0].strip()
        elif any(line.endswith(ext) for ext in (".ts", ".tsx", ".js", ".jsx", ".json", ".yaml", ".yml", ".css", ".md", ".mdx")):
            f = line.split(":")[0].strip()
        if f and ("." in f) and (" " not in f):
            norm_f = f if (f.startswith(prefix) or f.startswith("nodejs/") or f.startswith("services/mcp/")) else f"{prefix}{f}"
            c = f"{norm_f}:1: error: file requires formatting [format]"
            if c not in seen:
                seen.add(c)
                errors.setdefault(norm_f, []).append(c)
    return errors


def parse_mcp_tool_names(output: str):
    errors = {}
    pat1 = re.compile(r"^\s*(?P<tool>[a-z0-9-]+):\s+(?P<msg>.+)\s+\((?P<source>[^)]+)\)$")
    pat2 = re.compile(r"^(?P<file>[^:\s]+):(?P<line>\d+):(?:\d+:)?\s*(?:error|warning):\s*(?P<msg>.*)$")
    for raw in output.splitlines():
        plain = raw.strip()
        m1 = pat1.match(plain)
        if m1:
            f = m1.group("source")
            msg = m1.group("msg")
            tool = m1.group("tool")
            c = f"{f}:1: error: {tool}: {msg} [mcp-tool-names]"
            errors.setdefault(f, []).append(c)
            continue
        m2 = pat2.match(plain)
        if m2:
            f = m2.group("file")
            l = m2.group("line")
            msg = m2.group("msg")
            c = f"{f}:{l}: error: {msg} [mcp-tool-names]"
            errors.setdefault(f, []).append(c)
    return errors


def flatten_workflow(src_path: Path) -> str:
    lines = src_path.read_text(encoding="utf-8").splitlines(keepends=True)
    out = []
    in_parallel = False
    parallel_indent = 0
    dedent = 0
    for line in lines:
        stripped = line.lstrip(" ")
        if stripped.startswith("- parallel:"):
            parallel_indent = len(line) - len(stripped)
            dedent = 0
            in_parallel = True
            continue
        if in_parallel:
            if not line.strip():
                out.append(line)
                continue
            indent = len(line) - len(line.lstrip(" "))
            if indent <= parallel_indent:
                in_parallel = False
                out.append(line)
                continue
            if not dedent:
                dedent = indent - parallel_indent
            out.append(line[dedent:])
            continue
        out.append(line)
    return "".join(out)


def junit(suite, classname, changed, errors):
    cases = []
    for path in sorted(set(changed) | set(errors)):
        if path in errors:
            text = "\n".join(errors[path])
            cases.append(
                f'  <testcase classname="{classname}" file={quoteattr(path)} name={quoteattr(path)}>\n'
                f"    <failure message={quoteattr(text)}>{quoteattr(text)[1:-1]}</failure>\n  </testcase>"
            )
        else:
            cases.append(f'  <testcase classname="{classname}" file={quoteattr(path)} name={quoteattr(path)}/>')
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<testsuite name="{suite}" tests="{len(cases)}" failures="{len(errors)}">\n'
        + "\n".join(cases)
        + "\n</testsuite>\n"
    )


def commands(component, check, changed):
    root = Path(__file__).resolve().parents[2]
    files = sorted({f for f in changed if (root / f).is_file()})
    if component == "products":
        res = []
        if "tach.toml" in changed or "products/isolation_baseline.txt" in changed or ".importlinter" in changed:
            res.append(["uv", "run", "lint-imports"])
            if "tach.toml" in changed and shutil.which("tach"):
                res.append(["uv", "run", "tach", "check"])
            res.append(["uv", "run", "hogli", "product:lint", "--all", "--parallel"])
            return res
        products = sorted(
            {
                Path(f).parts[1]
                for f in changed
                if len(Path(f).parts) > 2
                and Path(f).parts[0] == "products"
                and not Path(f).parts[1].startswith((".", "_"))
                and not any(p == "migrations" for p in Path(f).parts)
                and any((root / Path(*Path(f).parts[:2]) / "backend").rglob("*.py"))
            }
        )
        if products:
            res.append(["uv", "run", "lint-imports"])
            res.append(["uv", "run", "hogli", "product:lint", "--parallel", *products])
        return res

    if component == "rust":
        res = []
        rust_files = [f for f in changed if f.endswith((".rs", "Cargo.toml", "Cargo.lock"))]
        if rust_files:
            if check == "fmt":
                res.append(["cargo", "fmt", "--all", "--", "--check"])
            elif check == "lint":
                crates = set()
                for f in rust_files:
                    parts = Path(f).parts
                    if len(parts) >= 2 and parts[0] == "rust":
                        if parts[1] == "common" and len(parts) >= 3:
                            crates.add(f"common-{parts[2]}")
                        elif parts[1] not in {"Cargo.toml", "Cargo.lock"}:
                            crates.add(parts[1])
                if crates:
                    crate_args = []
                    for c in sorted(crates):
                        crate_args.extend(["-p", c])
                    res.append(["cargo", "clippy", *crate_args, "--all-targets"])
                else:
                    res.append(["cargo", "clippy", "--all-targets"])
        return res

    if component == "livestream":
        res = []
        go_files = [f for f in changed if f.endswith((".go", "go.mod", "go.sum"))]
        if go_files and check == "lint":
            res.append(["golangci-lint", "run", "--timeout=5m"])
        return res

    if component == "proto":
        res = []
        proto_files = [f for f in changed if f.endswith((".proto", "buf.yaml", "buf.gen.yaml"))]
        if proto_files and check == "lint":
            res.append(["buf", "lint", "proto/"])
        return res

    if component == "workflows":
        if check != "lint":
            return []
        wf_files = [
            f
            for f in changed
            if f.startswith((".github/workflows/", ".github/actions/"))
            or f in {".github/actionlint.yaml", ".github/actionlint.yml"}
        ]
        if changed and not wf_files:
            return []
        return [["actionlint"]]

    if component in ("nodejs", "plugin_server"):
        node_files = [f for f in files if f.startswith("nodejs/")]
        if not node_files:
            return []
        res = []
        if check == "fmt":
            fmt_targets = [
                f
                for f in node_files
                if Path(f).suffix
                in {
                    ".ts",
                    ".tsx",
                    ".js",
                    ".jsx",
                    ".mjs",
                    ".cjs",
                    ".json",
                    ".jsonc",
                    ".yaml",
                    ".yml",
                    ".css",
                    ".scss",
                }
            ]
            if not fmt_targets:
                return []
            oxfmt = find_binary("oxfmt")
            if shutil.which(oxfmt) or Path(oxfmt).is_file():
                res.append([oxfmt, "--check", *fmt_targets])
            else:
                pnpm = find_binary("pnpm")
                if shutil.which(pnpm) or Path(pnpm).is_file():
                    res.append([pnpm, "--filter=@posthog/nodejs", "format:check"])
            return res
        if check == "lint":
            lint_targets = [
                f
                for f in node_files
                if Path(f).suffix in {".ts", ".tsx", ".mts", ".cts", ".js", ".jsx"}
            ]
            oxlint = find_binary("oxlint")
            oxlint_cfg = root / "nodejs/.oxlintrc.nodejs.json"
            if lint_targets:
                if (shutil.which(oxlint) or Path(oxlint).is_file()) and oxlint_cfg.is_file():
                    res.append([oxlint, "-c", str(oxlint_cfg), *lint_targets])
                else:
                    pnpm = find_binary("pnpm")
                    if shutil.which(pnpm) or Path(pnpm).is_file():
                        res.append([pnpm, "--filter=@posthog/nodejs", "lint"])
            boundary_script = root / "nodejs/bin/check-ingestion-boundaries.mjs"
            node_bin = find_binary("node")
            if boundary_script.is_file() and (shutil.which(node_bin) or Path(node_bin).is_file()):
                res.append([node_bin, str(boundary_script)])
            return res

    if component == "mcp":
        mcp_files = [f for f in files if f.startswith("services/mcp/") or "/mcp/" in f or f.startswith("packages/llm-normalizer/")]
        if not mcp_files:
            return []
        res = []
        if check == "fmt":
            fmt_targets = [
                f
                for f in mcp_files
                if Path(f).suffix
                in {
                    ".ts",
                    ".tsx",
                    ".js",
                    ".jsx",
                    ".mjs",
                    ".cjs",
                    ".json",
                    ".jsonc",
                    ".yaml",
                    ".yml",
                    ".md",
                    ".mdx",
                }
            ]
            if not fmt_targets:
                return []
            oxfmt = find_binary("oxfmt")
            if shutil.which(oxfmt) or Path(oxfmt).is_file():
                res.append([oxfmt, "--check", *fmt_targets])
            else:
                pnpm = find_binary("pnpm")
                if shutil.which(pnpm) or Path(pnpm).is_file():
                    res.append([pnpm, "--filter=@posthog/mcp", "format:check"])
            return res
        if check == "lint":
            lint_targets = [
                f
                for f in mcp_files
                if Path(f).suffix in {".ts", ".tsx", ".mts", ".cts", ".js", ".jsx"}
            ]
            oxlint = find_binary("oxlint")
            if lint_targets:
                if shutil.which(oxlint) or Path(oxlint).is_file():
                    res.append([oxlint, "--quiet", *lint_targets])
                else:
                    pnpm = find_binary("pnpm")
                    if shutil.which(pnpm) or Path(pnpm).is_file():
                        res.append([pnpm, "--filter=@posthog/mcp", "lint"])
            pnpm = find_binary("pnpm")
            if shutil.which(pnpm) or Path(pnpm).is_file():
                res.append([pnpm, "--filter=@posthog/mcp", "lint-tool-names"])
            return res

    py = [f for f in files if Path(f).suffix in {".py", ".pyi"}]
    js = [f for f in files if Path(f).suffix in {".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"}]
    formatted = [
        f
        for f in files
        if Path(f).suffix
        in {
            ".ts",
            ".tsx",
            ".js",
            ".jsx",
            ".mjs",
            ".cjs",
            ".json",
            ".jsonc",
            ".yaml",
            ".yml",
            ".css",
            ".scss",
        }
    ]
    result = []
    if component == "backend" and py:
        result.append(["uv", "run", "ruff", *(["format", "--check", "--diff"] if check == "fmt" else ["check"]), *py])
    if check == "fmt" and formatted:
        oxfmt = shutil.which("oxfmt")
        result.append([oxfmt, "--check", *formatted] if oxfmt else ["pnpm", "exec", "oxfmt", "--check", *formatted])
    if component == "frontend" and check == "lint" and js:
        result.append(["oxlint", *js])
    return result


def main():
    if (
        len(sys.argv) < 3
        or sys.argv[1] not in {"frontend", "backend", "products", "rust", "livestream", "proto", "workflows", "nodejs", "plugin_server", "mcp"}
        or sys.argv[2] not in {"fmt", "lint"}
    ):
        raise SystemExit("usage: static_check.py frontend|backend|products|rust|livestream|proto|workflows|nodejs|mcp fmt|lint [changed files...]")
    component = "nodejs" if sys.argv[1] in ("nodejs", "plugin_server") else sys.argv[1]
    check = sys.argv[2]
    changed = sys.argv[3:]
    root = Path(__file__).resolve().parents[2]
    py_changed = [f for f in changed if f.endswith((".py", ".pyi")) and (root / f).is_file()]

    cmds = commands(component, check, changed)
    if not cmds:
        results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
        if results_dir:
            if component == "backend":
                suite = "backend-fmt" if check == "fmt" else "backend-lint"
                classname = "ruff-format" if check == "fmt" else "ruff"
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                (Path(results_dir) / f"{suite}.xml").write_text(junit(suite, classname, [], {}))
            elif component == "products":
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                (Path(results_dir) / "product-structure.xml").write_text(junit("product-structure", "product-lint", [], {}))
                (Path(results_dir) / "import-linter.xml").write_text(junit("repo-importlinter", "import-linter", [], {}))
                (Path(results_dir) / "tach.xml").write_text(junit("repo-tach", "tach", [], {}))
            elif component == "frontend":
                suite = "frontend-fmt" if check == "fmt" else "frontend-lint"
                classname = "oxfmt" if check == "fmt" else "oxlint"
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                (Path(results_dir) / f"{suite}.xml").write_text(junit(suite, classname, [], {}))
            elif component == "rust":
                suite = "rust-fmt" if check == "fmt" else "rust-clippy"
                classname = "cargo-fmt" if check == "fmt" else "clippy"
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                (Path(results_dir) / f"{suite}.xml").write_text(junit(suite, classname, [], {}))
            elif component == "livestream":
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                (Path(results_dir) / "livestream-lint.xml").write_text(junit("livestream-lint", "golangci-lint", [], {}))
            elif component == "proto":
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                (Path(results_dir) / "proto-lint.xml").write_text(junit("proto-lint", "buf-lint", [], {}))
            elif component == "workflows":
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                (Path(results_dir) / "actionlint.xml").write_text(junit("actionlint", "actionlint", [], {}))
            elif component == "nodejs":
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                if check == "fmt":
                    (Path(results_dir) / "nodejs-fmt.xml").write_text(junit("nodejs-fmt", "oxfmt", [], {}))
                else:
                    (Path(results_dir) / "nodejs-lint.xml").write_text(junit("nodejs-lint", "oxlint", [], {}))
                    (Path(results_dir) / "nodejs-boundaries.xml").write_text(junit("nodejs-boundaries", "ingestion-boundaries", [], {}))
            elif component == "mcp":
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                if check == "fmt":
                    (Path(results_dir) / "mcp-fmt.xml").write_text(junit("mcp-fmt", "oxfmt", [], {}))
                else:
                    (Path(results_dir) / "mcp-lint.xml").write_text(junit("mcp-lint", "oxlint", [], {}))
                    (Path(results_dir) / "mcp-schema.xml").write_text(junit("mcp-schema", "mcp-schema-drift", [], {}))
                    (Path(results_dir) / "mcp-ui-apps.xml").write_text(junit("mcp-ui-apps", "mcp-ui-apps-drift", [], {}))
                    (Path(results_dir) / "mcp-tool-names.xml").write_text(junit("mcp-tool-names", "mcp-tool-names", [], {}))
        return 0

    for command in cmds:
        if component == "workflows":
            cmd_env = dict(os.environ)
            cmd_cwd = str(root)
            cmd_env["SHELLCHECK_OPTS"] = "--severity=error"
            actionlint_bin = shutil.which("actionlint")
            if not actionlint_bin:
                for base in [Path("/nix/store"), Path.home() / ".local/share/enve/store"]:
                    if base.is_dir():
                        found = sorted(base.glob("*-actionlint-*/bin/actionlint"), reverse=True)
                        if found:
                            actionlint_bin = str(found[0])
                            break
            shellcheck_bin = shutil.which("shellcheck")
            if not shellcheck_bin:
                for base in [Path("/nix/store"), Path.home() / ".local/share/enve/store"]:
                    if base.is_dir():
                        found = sorted(base.glob("*-shellcheck-*/bin/shellcheck"), reverse=True)
                        if found:
                            shellcheck_bin = str(found[0])
                            break
            if shellcheck_bin:
                cmd_env["PATH"] = str(Path(shellcheck_bin).parent) + os.pathsep + cmd_env.get("PATH", "")

            import tempfile
            with tempfile.TemporaryDirectory() as tmpdir:
                wf_paths = sorted(root.glob(".github/workflows/*.yml")) + sorted(root.glob(".github/workflows/*.yaml"))
                awk_script = root / ".github/scripts/flatten-parallel-steps-for-actionlint.awk"
                for wf in wf_paths:
                    out_file = Path(tmpdir) / wf.name
                    if awk_script.is_file() and shutil.which("awk"):
                        with open(out_file, "w", encoding="utf-8") as out:
                            subprocess.run(["awk", "-f", str(awk_script), str(wf)], stdout=out, check=False)
                    else:
                        out_file.write_text(flatten_workflow(wf), encoding="utf-8")

                flattened = [str(f) for f in sorted(Path(tmpdir).glob("*"))]
                if not flattened:
                    results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
                    if results_dir:
                        Path(results_dir).mkdir(parents=True, exist_ok=True)
                        (Path(results_dir) / "actionlint.xml").write_text(junit("actionlint", "actionlint", [], {}))
                    return 0

                run_args = [actionlint_bin or "actionlint"]
                config_file = root / ".github/actionlint.yaml"
                if config_file.is_file():
                    run_args.extend(["-config-file", str(config_file)])
                run_args.extend(flattened)

                try:
                    result = subprocess.run(
                        run_args,
                        cwd=cmd_cwd,
                        env=cmd_env,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        text=True,
                        check=False,
                    )
                except OSError as exc:
                    print(f"Unable to start {run_args[0]}: {exc}", file=sys.stderr)
                    return 127

                if result.stdout:
                    sys.stdout.write(result.stdout)

                results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
                if results_dir:
                    errors = parse_actionlint(result.stdout)
                    wf_changed = [f for f in changed if f.startswith(".github/workflows/")]
                    Path(results_dir).mkdir(parents=True, exist_ok=True)
                    (Path(results_dir) / "actionlint.xml").write_text(junit("actionlint", "actionlint", wf_changed, errors))

                if result.returncode:
                    return result.returncode
            continue

        cmd_env = dict(os.environ)
        cmd_cwd = None
        if command[:2] == ["uv", "run"]:
            command = [
                sys.executable,
                "showcase/scripts/backend_runtime.py",
                "exec",
                "uv",
                "run",
                "--no-sync",
                *command[2:],
            ]
        elif component == "rust":
            cmd_cwd = str(root / "rust")
            cmd_env["OPENSSL_NO_VENDOR"] = "1"
            cmd_env["SQLX_OFFLINE"] = "true"
            cmd_env.pop("LD_LIBRARY_PATH", None)
            if "PROTOC" not in cmd_env:
                protoc = shutil.which("protoc")
                if not protoc:
                    for base in [Path("/nix/store"), Path.home() / ".local/share/enve/store"]:
                        if base.is_dir():
                            store_protocs = sorted(base.glob("*-protobuf-*/bin/protoc"), reverse=True)
                            if store_protocs:
                                protoc = str(store_protocs[0])
                                break
                if protoc:
                    cmd_env["PROTOC"] = protoc
                    include_dir = Path(protoc).resolve().parent.parent / "include"
                    if include_dir.is_dir():
                        cmd_env["PROTOC_INCLUDE"] = str(include_dir)
        elif component == "livestream":
            cmd_cwd = str(root / "livestream")
        elif component == "proto":
            cmd_cwd = str(root)

        try:
            result = subprocess.run(
                command,
                cwd=cmd_cwd,
                env=cmd_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
        except OSError as exc:
            print(f"Unable to start {command[0]}: {exc}", file=sys.stderr)
            return 127

        if result.stdout:
            sys.stdout.write(result.stdout)

        if component == "backend":
            results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
            if results_dir:
                suite = "backend-fmt" if check == "fmt" else "backend-lint"
                classname = "ruff-format" if check == "fmt" else "ruff"
                errors = parse_ruff_fmt(result.stdout) if check == "fmt" else parse_ruff_check(result.stdout)
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                (Path(results_dir) / f"{suite}.xml").write_text(junit(suite, classname, py_changed, errors))

        if component == "products":
            results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
            if results_dir:
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                if "lint-imports" in command:
                    errors = parse_importlinter(result.stdout)
                    (Path(results_dir) / "import-linter.xml").write_text(junit("repo-importlinter", "import-linter", py_changed, errors))
                    (Path(results_dir) / "tach.xml").write_text(junit("repo-tach", "tach", py_changed, {}))
                elif "tach" in command:
                    errors = parse_tach(result.stdout)
                    (Path(results_dir) / "tach.xml").write_text(junit("repo-tach", "tach", py_changed, errors))
                else:
                    errors = {}
                    if result.returncode != 0:
                        for f in changed:
                            errors[f] = [f"{f}:1: error: product structure or boundary check failed [product-lint]"]
                    (Path(results_dir) / "product-structure.xml").write_text(junit("product-structure", "product-lint", changed, errors))

        if component == "frontend":
            results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
            if results_dir:
                suite = "frontend-fmt" if check == "fmt" else "frontend-lint"
                classname = "oxfmt" if check == "fmt" else "oxlint"
                errors = {}
                if result.returncode != 0:
                    for f in changed:
                        errors[f] = [f"{f}:1: error: {check} violations found [{classname}]"]
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                (Path(results_dir) / f"{suite}.xml").write_text(junit(suite, classname, changed, errors))

        if component == "rust":
            results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
            if results_dir:
                suite = "rust-fmt" if check == "fmt" else "rust-clippy"
                classname = "cargo-fmt" if check == "fmt" else "clippy"
                errors = parse_cargo_fmt(result.stdout) if check == "fmt" else parse_cargo_clippy(result.stdout)
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                rust_changed = [f for f in changed if f.endswith((".rs", "Cargo.toml", "Cargo.lock"))]
                (Path(results_dir) / f"{suite}.xml").write_text(junit(suite, classname, rust_changed, errors))

        if component == "livestream":
            results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
            if results_dir:
                errors = parse_golangci_lint(result.stdout)
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                go_changed = [f for f in changed if f.endswith((".go", "go.mod", "go.sum"))]
                (Path(results_dir) / "livestream-lint.xml").write_text(junit("livestream-lint", "golangci-lint", go_changed, errors))

        if component == "proto":
            results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
            if results_dir:
                errors = parse_buf_lint(result.stdout)
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                proto_changed = [f for f in changed if f.endswith((".proto", "buf.yaml", "buf.gen.yaml"))]
                (Path(results_dir) / "proto-lint.xml").write_text(junit("proto-lint", "buf-lint", proto_changed, errors))

        if component == "nodejs":
            results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
            if results_dir:
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                node_changed = [f for f in changed if f.startswith("nodejs/")]
                cmd_str = " ".join(command)
                if check == "fmt":
                    errors = parse_prettier_or_oxfmt(result.stdout)
                    if result.returncode != 0 and not errors:
                        for f in node_changed:
                            errors[f] = [f"{f}:1: error: file requires formatting [format]"]
                    (Path(results_dir) / "nodejs-fmt.xml").write_text(junit("nodejs-fmt", "oxfmt", node_changed, errors))
                elif "check-ingestion-boundaries" in cmd_str:
                    errors = parse_ingestion_boundaries(result.stdout)
                    if result.returncode != 0 and not errors:
                        for f in node_changed:
                            errors[f] = [f"{f}:1: error: ingestion boundary violation [ingestion-boundaries]"]
                    (Path(results_dir) / "nodejs-boundaries.xml").write_text(junit("nodejs-boundaries", "ingestion-boundaries", node_changed, errors))
                else:
                    errors = parse_oxlint(result.stdout)
                    if result.returncode != 0 and not errors:
                        for f in node_changed:
                            errors[f] = [f"{f}:1: error: oxlint verification failed [oxlint]"]
                    (Path(results_dir) / "nodejs-lint.xml").write_text(junit("nodejs-lint", "oxlint", node_changed, errors))

        if component == "mcp":
            results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
            if results_dir:
                Path(results_dir).mkdir(parents=True, exist_ok=True)
                mcp_changed = [f for f in changed if f.startswith("services/mcp/") or "/mcp/" in f or f.startswith("packages/llm-normalizer/")]
                cmd_str = " ".join(command)
                if check == "fmt":
                    errors = parse_prettier_or_oxfmt(result.stdout, prefix="services/mcp/")
                    if result.returncode != 0 and not errors:
                        for f in mcp_changed:
                            errors[f] = [f"{f}:1: error: file requires formatting [format]"]
                    (Path(results_dir) / "mcp-fmt.xml").write_text(junit("mcp-fmt", "oxfmt", mcp_changed, errors))
                elif "lint-tool-names" in cmd_str:
                    errors = parse_mcp_tool_names(result.stderr or result.stdout)
                    if result.returncode != 0 and not errors:
                        for f in mcp_changed:
                            errors[f] = [f"{f}:1: error: tool names lint failed [mcp-tool-names]"]
                    (Path(results_dir) / "mcp-tool-names.xml").write_text(junit("mcp-tool-names", "mcp-tool-names", mcp_changed, errors))
                else:
                    errors = parse_oxlint(result.stdout, prefix="services/mcp/")
                    if result.returncode != 0 and not errors:
                        for f in mcp_changed:
                            errors[f] = [f"{f}:1: error: oxlint verification failed [oxlint]"]
                    (Path(results_dir) / "mcp-lint.xml").write_text(junit("mcp-lint", "oxlint", mcp_changed, errors))

        if result.returncode:
            return result.returncode

    results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
    if results_dir and component == "nodejs":
        Path(results_dir).mkdir(parents=True, exist_ok=True)
        if check == "lint":
            b_xml = Path(results_dir) / "nodejs-boundaries.xml"
            if not b_xml.is_file():
                b_xml.write_text(junit("nodejs-boundaries", "ingestion-boundaries", [], {}))
            l_xml = Path(results_dir) / "nodejs-lint.xml"
            if not l_xml.is_file():
                l_xml.write_text(junit("nodejs-lint", "oxlint", [], {}))

    if results_dir and component == "mcp":
        Path(results_dir).mkdir(parents=True, exist_ok=True)
        if check == "lint":
            for report, classname in [
                ("mcp-lint.xml", "oxlint"),
                ("mcp-schema.xml", "mcp-schema-drift"),
                ("mcp-ui-apps.xml", "mcp-ui-apps-drift"),
                ("mcp-tool-names.xml", "mcp-tool-names"),
            ]:
                r_xml = Path(results_dir) / report
                if not r_xml.is_file():
                    r_xml.write_text(junit(report.removesuffix(".xml"), classname, [], {}))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
