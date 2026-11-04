import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("template_publications.py")
if not SCRIPT.is_file():
    SCRIPT = Path(__file__).resolve().parents[1] / "template_publications.py"


def publish(root: Path, key: str = "a" * 64) -> Path:
    directory = root / key / "v3.ABCDef12"
    directory.mkdir(parents=True)
    (directory.parent / "current-v3").write_text("v3.ABCDef12\n")
    lines = [f"enact-test-template-v3:{key} pg15"]
    for name in ("postgres.dump", "persons.dump", "migrations.json"):
        data = f"synthetic {name}\n".encode()
        (directory / name).write_bytes(data)
        lines.append(f"{hashlib.sha256(data).hexdigest()}  {name}")
    (directory / "manifest").write_text("\n".join(lines) + "\n")
    return directory


class PublicationTest(unittest.TestCase):
    def check(self, root: Path, eligible: bool, code: int = 0) -> None:
        output = root.parent / "github-output"
        output.unlink(missing_ok=True)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(root)],
            env={**os.environ, "GITHUB_OUTPUT": str(output)},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, code, result.stderr)
        self.assertEqual(output.read_text(), f"eligible={str(eligible).lower()}\n")
        if code:
            self.assertIn("Template transport refused:", result.stderr)

    def test_missing_empty_and_multiple_complete_publications(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work).resolve() / "v3"
            self.check(root, False)
            root.mkdir()
            self.check(root, False)
            publish(root)
            publish(root, "b" * 64)
            self.check(root, True)

    def test_incomplete_corrupt_and_unsupported_publications(self) -> None:
        for change in (
            "pointer-missing",
            "pointer-escape",
            "pointer-trailing",
            "dump-missing",
            "dump-corrupt",
            "dump-empty",
            "migrations-missing",
            "manifest-missing",
            "manifest-identity",
            "manifest-command",
            "manifest-filename",
            "manifest-duplicate",
            "manifest-extra",
            "unfinished",
            "unexpected-file",
            "bad-key",
        ):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as work:
                root = Path(work).resolve() / "v3"
                directory = publish(root)
                self.mutate(directory, change)
                self.check(root, False, 1)

    def mutate(self, directory: Path, change: str) -> None:
        manifest = directory / "manifest"
        pointer = directory.parent / "current-v3"
        if change == "pointer-missing":
            pointer.unlink()
        elif change == "pointer-escape":
            pointer.write_text("../../elsewhere\n")
        elif change == "pointer-trailing":
            pointer.write_text("v3.ABCDef12\nextra\n")
        elif change == "dump-missing":
            (directory / "persons.dump").unlink()
        elif change == "dump-corrupt":
            (directory / "persons.dump").write_bytes(b"corrupt")
        elif change == "dump-empty":
            (directory / "persons.dump").write_bytes(b"")
        elif change == "migrations-missing":
            (directory / "migrations.json").unlink()
        elif change == "manifest-missing":
            manifest.unlink()
        elif change == "manifest-identity":
            manifest.write_text(manifest.read_text().replace("a" * 64, "b" * 64))
        elif change == "manifest-command":
            manifest.write_text("$(touch executed)\n")
        elif change == "manifest-filename":
            manifest.write_text(
                manifest.read_text().replace("persons.dump", "../outside")
            )
        elif change == "manifest-duplicate":
            manifest.write_text(
                manifest.read_text().replace("persons.dump", "postgres.dump")
            )
        elif change == "manifest-extra":
            manifest.write_text(manifest.read_text() + "unexpected\n")
        elif change == "unfinished":
            (directory.parent / "v3.unfinish").mkdir()
        elif change == "unexpected-file":
            (directory / "extra").write_text("unfinished")
        elif change == "bad-key":
            directory.parent.rename(directory.parent.with_name("invalid-key"))

    def test_symlinks_and_special_files_are_refused(self) -> None:
        for part in (
            "root",
            "ancestor",
            "key",
            "generation",
            "pointer",
            "dump",
            "manifest",
            "fifo",
        ):
            with self.subTest(part=part), tempfile.TemporaryDirectory() as work:
                root = Path(work).resolve() / "snapshots" / "v3"
                directory = publish(root)
                path = {
                    "root": root,
                    "ancestor": root.parent,
                    "key": directory.parent,
                    "generation": directory,
                    "pointer": directory.parent / "current-v3",
                    "dump": directory / "persons.dump",
                    "manifest": directory / "manifest",
                    "fifo": directory / "persons.dump",
                }[part]
                target = Path(work).resolve() / "original"
                path.rename(target)
                if part == "fifo":
                    os.mkfifo(path)
                else:
                    path.symlink_to(target)
                self.check(root, False, 1)

    def test_the_cold_build_note_beside_the_publications_is_no_publication(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work).resolve() / "v3"
            root.mkdir()
            (root / "cold-build-seconds").write_text("612\n")
            self.check(root, False)
            publish(root)
            self.check(root, True)
            (root / "cold-build-seconds").unlink()
            (root / "cold-build-seconds").mkdir()
            self.check(root, False, 1)

    def test_one_bad_publication_refuses_the_entire_archive(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work).resolve() / "v3"
            publish(root)
            directory = publish(root, "b" * 64)
            (directory / "persons.dump").unlink()
            self.check(root, False, 1)


if __name__ == "__main__":
    unittest.main()
