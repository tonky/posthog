"""Check complete v3 publications before transport; delegates to `enact helper pg-template verify`."""

import os
import shutil
import sys


def main() -> int:
    enact = os.environ.get("ENACT_EXE") or os.environ.get("ENACT_BIN") or shutil.which("enact") or "enact"
    os.execv(enact, [enact, "helper", "pg-template", "verify", *sys.argv[1:]])


if __name__ == "__main__":
    sys.exit(main())
