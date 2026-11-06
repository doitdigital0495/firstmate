#!/usr/bin/env bash
# fm-skill-registry-check.sh - validate agent skill registration and the trigger index.
#
# Usage:
#   bin/fm-skill-registry-check.sh
#   bin/fm-skill-registry-check.sh --root <repo>
#
# Reads every tracked .agents/skills/<dir>/SKILL.md under the root and fails when:
#   - its front matter lacks a name equal to <dir>, a non-empty description, or
#     user-invocable: true|false;
#   - an agent-only skill (user-invocable: false) other than
#     agent-skill-trigger-index has no description trigger containing "load";
#   - an agent-only skill other than agent-skill-trigger-index is missing from, or
#     listed more than once in, that index's "- `<name>` - <trigger>" entries;
#   - an index entry names no tracked agent-only skill or states no "load" trigger;
#   - an AGENTS.md "load `<name>`" pointer names no tracked skill.
# Prints one "fm-skill-registry-check: ok ..." summary line on success and one
# "fm-skill-registry-check: <problem>" line per failure otherwise (exit 1).
# Structure only: it never judges whether a trigger is well chosen.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in
  -h|--help) awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
  --root)
    [ "$#" -eq 2 ] && [ -n "$2" ] || { echo 'fm-skill-registry-check: --root needs a directory' >&2; exit 2; }
    ROOT=$2 ;;
  '') ;;
  *) echo "fm-skill-registry-check: unknown argument $1" >&2; exit 2 ;;
esac
[ -d "$ROOT" ] || { echo "fm-skill-registry-check: root is not a directory: $ROOT" >&2; exit 2; }

exec python3 - "$ROOT" <<'PY'
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

INDEX = "agent-skill-trigger-index"
ENTRY_RE = re.compile(r"^- `([^`]+)` - (.+)$")
POINTER_RE = re.compile(r"\b[Ll]oad(?: the)? `/?([a-z0-9][a-z0-9-]*)`")
KEY_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*):(.*)$")

root = Path(sys.argv[1])
problems: list[str] = []


def tracked_skill_files() -> list[str]:
    proc = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", ".agents/skills/*/SKILL.md"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        print(f"fm-skill-registry-check: git ls-files failed: {detail or 'unknown error'}")
        sys.exit(1)
    paths = [p for p in proc.stdout.decode("utf-8").split("\0") if p]
    return sorted(p for p in paths if len(Path(p).parts) == 4)


def front_matter(text: str) -> dict[str, str] | None:
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        return None
    fields: dict[str, str] = {}
    key = None
    for line in lines[1:end]:
        if line[:1] in (" ", "\t"):
            if key is not None:
                fields[key] = (fields[key] + " " + line.strip()).strip()
            continue
        match = KEY_RE.match(line)
        if not match:
            key = None
            continue
        key, value = match.group(1), match.group(2).strip()
        fields[key] = "" if value in (">", ">-", "|", "|-") else value.strip("'\"")
    return fields


skills: dict[str, dict[str, str]] = {}
for rel in tracked_skill_files():
    directory = Path(rel).parts[2]
    try:
        text = (root / rel).read_text(encoding="utf-8")
    except OSError as exc:
        problems.append(f"{rel}: unreadable: {exc}")
        continue
    fields = front_matter(text)
    if fields is None:
        problems.append(f"{rel}: missing --- front matter")
        continue
    if fields.get("name") != directory:
        problems.append(f"{rel}: name must equal its directory {directory!r}, got {fields.get('name')!r}")
    if not fields.get("description"):
        problems.append(f"{rel}: description is missing or empty")
    invocable = fields.get("user-invocable")
    if invocable not in ("true", "false"):
        problems.append(f"{rel}: user-invocable must be true or false, got {invocable!r}")
    skills[directory] = fields

agent_only = sorted(
    name for name, fields in skills.items() if fields.get("user-invocable") == "false" and name != INDEX
)
for name in agent_only:
    if "load" not in skills[name].get("description", "").lower():
        problems.append(f".agents/skills/{name}/SKILL.md: agent-only description states no load trigger")

index_path = root / ".agents" / "skills" / INDEX / "SKILL.md"
entries: dict[str, int] = {}
if INDEX not in skills:
    problems.append(f".agents/skills/{INDEX}/SKILL.md: trigger index is not tracked")
else:
    for number, line in enumerate(index_path.read_text(encoding="utf-8").split("\n"), 1):
        match = ENTRY_RE.match(line)
        if not match:
            continue
        name, trigger = match.group(1), match.group(2)
        entries[name] = entries.get(name, 0) + 1
        if name not in agent_only:
            problems.append(f"trigger index line {number}: `{name}` is not a tracked agent-only skill")
        if "load" not in trigger.lower():
            problems.append(f"trigger index line {number}: `{name}` states no load trigger")
    for name in agent_only:
        count = entries.get(name, 0)
        if count == 0:
            problems.append(f"trigger index: agent-only skill `{name}` is missing")
        elif count > 1:
            problems.append(f"trigger index: agent-only skill `{name}` is listed {count} times")

pointers = 0
agents_md = root / "AGENTS.md"
if agents_md.is_file():
    for number, line in enumerate(agents_md.read_text(encoding="utf-8").split("\n"), 1):
        for name in POINTER_RE.findall(line):
            pointers += 1
            if name not in skills:
                problems.append(f"AGENTS.md line {number}: load pointer `{name}` names no tracked skill")

if problems:
    for problem in problems:
        print(f"fm-skill-registry-check: {problem}")
    sys.exit(1)
print(
    f"fm-skill-registry-check: ok skills={len(skills)} agent_only={len(agent_only)} "
    f"indexed={len(entries)} agents_pointers={pointers}"
)
PY
