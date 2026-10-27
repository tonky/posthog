"""Check complete v3 publications before transport; restore still checks compatibility."""

import argparse
import hashlib
import os
import re
import stat
import sys
from dataclasses import dataclass
from pathlib import Path


# A dump pair and the migrations it applied (what a later key's miss tops up from).
SNAPSHOT_FILES = ("postgres.dump", "persons.dump", "migrations.json")
# test_databases.sh's note of how long this machine's last cold build took, beside the keys.
COLD_BUILD_SECONDS = "cold-build-seconds"


class PublicationError(ValueError):
    pass


def require_kind(path: Path, kind: int) -> None:
    if stat.S_IFMT(path.lstat().st_mode) != kind:
        raise PublicationError(f"Unsupported snapshot entry: {path}")


def require_entries(path: Path, expected: set[str]) -> None:
    require_kind(path, stat.S_IFDIR)
    if {entry.name for entry in path.iterdir()} != expected:
        raise PublicationError(f"Incomplete or unexpected snapshot entries: {path}")


def read_file(path: Path) -> str:
    require_kind(path, stat.S_IFREG)
    return path.read_text(encoding="ascii")


@dataclass(frozen=True)
class Publication:
    directory: Path
    key: str
    generation: str

    @classmethod
    def load(cls, directory: Path) -> "Publication":
        if not re.fullmatch(r"[a-f0-9]{64}", directory.name):
            raise PublicationError(f"Invalid template key: {directory}")
        require_kind(directory, stat.S_IFDIR)
        pointer = read_file(directory / "current-v3")
        if not re.fullmatch(r"v3\.[a-zA-Z0-9]{8}\n", pointer):
            raise PublicationError(f"Invalid snapshot generation: {directory}")
        generation = pointer.rstrip("\n")
        require_entries(directory, {"current-v3", generation})
        return cls(directory / generation, directory.name, generation)

    def verify(self) -> None:
        require_entries(self.directory, {"manifest", *SNAPSHOT_FILES})
        lines = read_file(self.directory / "manifest").splitlines()
        if len(lines) != 1 + len(SNAPSHOT_FILES) or not re.fullmatch(
            rf"enact-test-template-v3:{self.key} pg[1-9][0-9]*", lines[0]
        ):
            raise PublicationError(f"Invalid publication identity: {self.directory}")
        # Each file must match its fixed manifest position.
        for name, line in zip(SNAPSHOT_FILES, lines[1:], strict=True):
            if not re.fullmatch(rf"[a-f0-9]{{64}}  {re.escape(name)}", line):
                raise PublicationError(f"Invalid dump manifest: {self.directory}")
            dump = self.directory / name
            require_kind(dump, stat.S_IFREG)
            if dump.stat().st_size == 0:
                raise PublicationError(f"Empty snapshot dump: {dump}")
            with dump.open("rb") as stream:
                actual = hashlib.file_digest(stream, "sha256").hexdigest()
            if actual != line[:64]:
                raise PublicationError(f"Corrupt snapshot dump: {dump}")


def verify_tree(root: Path) -> int:
    root = root.absolute()
    # Do not follow a symlink in any part of the archived path.
    for ancestor in reversed((root, *root.parents)):
        if ancestor.is_symlink():
            raise PublicationError(f"Symlink snapshot path: {ancestor}")
    if not root.exists():
        return 0
    require_kind(root, stat.S_IFDIR)
    entries = sorted(root.iterdir())
    for note in (entry for entry in entries if entry.name == COLD_BUILD_SECONDS):
        require_kind(note, stat.S_IFREG)
    publications = [
        Publication.load(directory) for directory in entries if directory.name != COLD_BUILD_SECONDS
    ]
    for publication in publications:
        publication.verify()
    return len(publications)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    eligible = False
    code = 0
    try:
        count = verify_tree(args.root)
        eligible = count > 0
        print(f"Template transport: {count} complete publications", file=sys.stderr)
    except (OSError, ValueError) as error:
        print(f"Template transport refused: {error}", file=sys.stderr)
        code = 1
    output = f"eligible={'true' if eligible else 'false'}\n"
    if path := os.environ.get("GITHUB_OUTPUT"):
        with Path(path).open("a") as stream:
            stream.write(output)
    else:
        print(output, end="")
    return code


if __name__ == "__main__":
    sys.exit(main())
