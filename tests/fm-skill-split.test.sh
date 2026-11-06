#!/usr/bin/env bash
# Lossless-split proof for skills divided into a core SKILL.md plus references/.
#
# A split moves text verbatim: every non-blank, non-fence line of the pre-split
# SKILL.md must land in exactly one file of the split skill (the core or one
# reference), with its original multiplicity, and each file must keep the moved
# lines in their original order. The only tolerated byte change is a relative
# markdown link deepened by one `../` per directory level a reference sits below
# the skill directory, so the link still resolves from its new file. Lines no
# original carried are added text and are printed for review.
#
# Always runs: the checker's own cases on synthetic fixtures, and the routing
# invariants of every split skill in this checkout (core at most 8192 bytes,
# every references/ file named by its core, every named reference readable).
#
# Proof mode: FM_SKILL_SPLIT_BASE=<git-rev> also checks every skill that has a
# references/ directory now but had none at that revision, comparing against
# the revision's SKILL.md. Example: FM_SKILL_SPLIT_BASE=origin/main.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-skill-split)
CORE_MAX_BYTES=8192

# check_split <pre-split SKILL.md> <split skill dir>
# Exit 0 when the split is lossless; print one `added <file>: <line>` per new
# line, and one `error: ...` per violation on stderr.
check_split() {
  python3 -I - "$1" "$2" <<'PY'
import pathlib, re, sys
from collections import defaultdict

orig_path, skill_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
fence = re.compile(r"^\s*```[\w-]*\s*$")

def units(text):
    return [l for l in text.split("\n") if l.strip() and not fence.match(l)]

def restore_links(line, depth):
    if depth == 0:
        return line
    return re.sub(r"\]\(((?:\.\./)+)", lambda m: "](" + m.group(1)[3 * depth:] if len(m.group(1)) > 3 * depth else m.group(0), line)

orig = units(orig_path.read_text())
want = defaultdict(int)
for line in orig:
    want[line] += 1

files = [skill_dir / "SKILL.md"] + sorted((skill_dir / "references").rglob("*.md"))
errors = []
where = defaultdict(lambda: defaultdict(int))
for f in files:
    rel = f.relative_to(skill_dir)
    depth = len(rel.parts) - 1
    seen = defaultdict(int)
    last = -1
    for line in units(f.read_text()):
        line = restore_links(line, depth)
        if line not in want:
            print(f"added {rel}: {line}")
            continue
        seen[line] += 1
        where[line][str(rel)] += 1
        # Position of this occurrence among the original's copies of the line.
        positions = [i for i, l in enumerate(orig) if l == line]
        k = seen[line] - 1
        if k < len(positions):
            if positions[k] < last:
                errors.append(f"{rel}: moved line out of original order: {line[:80]}")
            last = max(last, positions[k])

for line, count in want.items():
    homes = where.get(line, {})
    total = sum(homes.values())
    if total == 0:
        errors.append(f"original line missing from the split: {line[:80]}")
    elif len(homes) != 1:
        errors.append(f"original line lands in {len(homes)} files ({', '.join(sorted(homes))}): {line[:80]}")
    elif total != count:
        errors.append(f"original line appears {total} times, original had {count}: {line[:80]}")

for e in errors:
    print(f"error: {e}", file=sys.stderr)
sys.exit(1 if errors else 0)
PY
}

# check_routing <split skill dir>: core size and reference naming invariants.
check_routing() {
  local dir=$1 core=$1/SKILL.md bytes ref rel
  bytes=$(wc -c < "$core" | tr -d ' ')
  [ "$bytes" -le "$CORE_MAX_BYTES" ] \
    || fail "$(basename "$dir") core SKILL.md is $bytes bytes, over $CORE_MAX_BYTES"
  while IFS= read -r ref; do
    rel=${ref#"$dir"/}
    grep -qF "$rel" "$core" || fail "$(basename "$dir") core does not name $rel"
  done < <(find "$dir/references" -type f -name '*.md' | sort)
  while IFS= read -r rel; do
    [ -r "$dir/$rel" ] || fail "$(basename "$dir") core names unreadable $rel"
  done < <(grep -oE 'references/[A-Za-z0-9_./-]+\.md' "$core" | sort -u)
}

make_fixture() {
  local d=$TMP_ROOT/$1
  mkdir -p "$d/orig" "$d/skill/references"
  printf '%s\n' '---' 'name: demo' '---' '' '# demo' '' 'Rule one stays.' '' \
    '## Procedure' '' 'Step one.' 'See [docs](../../../docs/x.md).' '' '```sh' 'run it' '```' '' \
    '## Notes' '' 'Note one.' > "$d/orig/SKILL.md"
  printf '%s\n' '---' 'name: demo' '---' '' '# demo' '' 'Rule one stays.' '' \
    '| Read | When |' "| \`references/procedure.md\` | running it |" > "$d/skill/SKILL.md"
  printf '%s\n' '# demo: procedure' '' '## Procedure' '' 'Step one.' \
    'See [docs](../../../../docs/x.md).' '' '```sh' 'run it' '```' '' \
    '## Notes' '' 'Note one.' > "$d/skill/references/procedure.md"
  printf '%s\n' "$d"
}

test_checker_accepts_lossless_split() {
  local d out
  d=$(make_fixture lossless)
  out=$(check_split "$d/orig/SKILL.md" "$d/skill" 2>&1) || fail "lossless fixture rejected: $out"
  case "$out" in *"added references/procedure.md: # demo: procedure"*) ;; *) fail "added heading not reported: $out" ;; esac
  case "$out" in *"See [docs]"*) fail "deepened link reported as added: $out" ;; esac
  pass "checker accepts a verbatim split and reports only added lines"
}

test_checker_rejects_lost_duplicated_reordered_edited() {
  local d out
  d=$(make_fixture lost)
  sed -i.bak '/^Note one\.$/d' "$d/skill/references/procedure.md"
  out=$(check_split "$d/orig/SKILL.md" "$d/skill" 2>&1) && fail "dropped line accepted"
  case "$out" in *"missing from the split: Note one."*) ;; *) fail "dropped line not named: $out" ;; esac

  d=$(make_fixture duplicated)
  printf '%s\n' 'Step one.' > "$d/skill/references/extra.md"
  out=$(check_split "$d/orig/SKILL.md" "$d/skill" 2>&1) && fail "line in two files accepted"
  case "$out" in *"lands in 2 files"*) ;; *) fail "duplicate not named: $out" ;; esac

  d=$(make_fixture reordered)
  printf '%s\n' '## Notes' 'Note one.' '## Procedure' 'Step one.' 'See [docs](../../../../docs/x.md).' 'run it' \
    > "$d/skill/references/procedure.md"
  out=$(check_split "$d/orig/SKILL.md" "$d/skill" 2>&1) && fail "reordered move accepted"
  case "$out" in *"out of original order"*) ;; *) fail "reorder not named: $out" ;; esac

  d=$(make_fixture edited)
  sed -i.bak 's/^Step one\.$/Step  one./' "$d/skill/references/procedure.md"
  out=$(check_split "$d/orig/SKILL.md" "$d/skill" 2>&1) && fail "reworded line accepted"
  case "$out" in *"missing from the split: Step one."*) ;; *) fail "reword not named: $out" ;; esac
  pass "checker rejects a dropped, duplicated, reordered, or reworded line"
}

test_split_skills_route_every_reference() {
  local dir count=0
  for dir in "$ROOT"/.agents/skills/*/; do
    dir=${dir%/}
    [ -d "$dir/references" ] || continue
    check_routing "$dir"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || fail "no split skill found under .agents/skills"
  pass "every split skill core is at most $CORE_MAX_BYTES bytes and names each reference ($count skills)"
}

test_splits_since_base_are_lossless() {
  local base=${FM_SKILL_SPLIT_BASE:-} dir name rel out checked=""
  if [ -z "$base" ]; then
    pass "split-since-base proof skipped: FM_SKILL_SPLIT_BASE is unset"
    return
  fi
  git -C "$ROOT" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
    || fail "FM_SKILL_SPLIT_BASE does not name a commit: $base"
  for dir in "$ROOT"/.agents/skills/*/; do
    dir=${dir%/}
    name=$(basename "$dir")
    rel=.agents/skills/$name
    [ -d "$dir/references" ] || continue
    git -C "$ROOT" cat-file -e "$base:$rel/references" 2>/dev/null && continue
    git -C "$ROOT" show "$base:$rel/SKILL.md" > "$TMP_ROOT/$name.orig.md" 2>/dev/null || continue
    out=$(check_split "$TMP_ROOT/$name.orig.md" "$dir" 2>&1) || fail "$name split is not lossless against $base: $out"
    printf '%s\n' "$out" | sed "s|^|# $name |"
    checked="$checked $name"
  done
  [ -n "$checked" ] || fail "no skill was split since $base"
  pass "skills split since $base are lossless:$checked"
}

fm_test_run \
  test_checker_accepts_lossless_split \
  test_checker_rejects_lost_duplicated_reordered_edited \
  test_split_skills_route_every_reference \
  test_splits_since_base_are_lossless
