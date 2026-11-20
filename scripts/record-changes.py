"""Record each first-parent change since the last versioned main commit."""

import json
import re
import subprocess
from pathlib import Path


def git(*args):
    return subprocess.check_output(["git", *args], text=True)


def main():
    version_file = Path("version.json")
    changelog = Path("CHANGELOG.md")
    state = json.loads(version_file.read_text())
    # A normal merge counts once. Ignore commits that only maintain these two files.
    commits = git(
        "rev-list", "--first-parent", "--reverse", state["lastChange"] + "..HEAD",
        "--", ".", ":(exclude)version.json", ":(exclude)CHANGELOG.md",
    ).splitlines()
    if not commits:
        return

    major, minor, patch = map(int, state["version"].split("."))
    entries = []
    for commit in commits:
        date, subject, body = git("show", "-s", "--format=%cs%n%s%n%b", commit).split("\n", 2)
        merge = re.fullmatch(r"Merge pull request #(\d+) from .+", subject)
        if merge and body.strip():
            subject = f"{body.strip().splitlines()[0]} (#{merge[1]})"
        patch += 1
        version = f"{major}.{minor}.{patch}"
        entries.append(f"## {version} ({date})\n\n- {subject}\n\n")

    history = changelog.read_text()
    first_entry = history.index("\n## ") + 1
    changelog.write_text(history[:first_entry] + "".join(reversed(entries)) + history[first_entry:])
    state.update(version=version, build=state["build"] + len(commits), lastChange=commits[-1])
    version_file.write_text(json.dumps(state, indent=2) + "\n")


if __name__ == "__main__":
    main()
