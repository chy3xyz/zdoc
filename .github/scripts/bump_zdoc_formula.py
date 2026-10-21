#!/usr/bin/env python3
"""Point Formula/zdoc.rb at one GitHub release.

Usage: bump_zdoc_formula.py Formula/zdoc.rb v0.16.3 SHA256SUMS

SHA256SUMS is the output of `sha256sum`. Only archives named by a `url` line
in the formula are updated. Other lines in the checksum file are ignored.
"""

import re
import sys
from pathlib import Path


def load_sums(path: Path) -> dict[str, str]:
    sums: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        sha, name = line.split(None, 1)
        sums[Path(name.strip()).name] = sha
    return sums


def main() -> None:
    formula = Path(sys.argv[1])
    tag = sys.argv[2]
    sums = load_sums(Path(sys.argv[3]))
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        sys.exit(f"tag must look like v1.2.3, got {tag}")

    text = formula.read_text()
    rewritten, n = re.subn(
        r"releases/download/v\d+\.\d+\.\d+/",
        f"releases/download/{tag}/",
        text,
    )
    if n == 0:
        sys.exit("formula has no release download urls")
    text = rewritten

    def replace_sha(match: re.Match[str]) -> str:
        filename = match.group(2)
        sha = sums.get(filename)
        if sha is None:
            sys.exit(f"SHA256SUMS has no entry for {filename}")
        return f"{match.group(1)}{filename}{match.group(3)}{sha}{match.group(4)}"

    text, updated = re.subn(
        r'(url "[^"]*/)([^"/]+)("\n\s*sha256 ")[0-9a-fA-F]+(")',
        replace_sha,
        text,
    )
    if updated == 0:
        sys.exit("formula has no sha256 lines to update")
    formula.write_text(text)
    print(f"updated {updated} archives to {tag}")


if __name__ == "__main__":
    main()
