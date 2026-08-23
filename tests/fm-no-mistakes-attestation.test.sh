#!/usr/bin/env bash
# Behavior of the "PR must be raised via no-mistakes" gate in
# .github/workflows/no-mistakes-required.yml.
#
# The step script is the executable contract here: this test parses the
# workflow into a semantic model, pulls out that step's `run` body, and runs it
# as GitHub Actions would, with PR_BODY fixtures.
#
# Regression origin: PR #7 was rejected with "structured pipeline step
# attestation is missing or unparseable" even though its body carried a valid
# attestation. Its evidence section quoted the attestation comment first (the
# placeholder from this check's own error text), and the check read only the
# first occurrence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-attestation)

STEP="$TMP_ROOT/step.sh"
python3 - "$WORKFLOW" "$STEP" <<'PY'
import sys, yaml

wf = yaml.safe_load(open(sys.argv[1]))
steps = wf["jobs"]["check"]["steps"]
run = [s["run"] for s in steps if s["name"] == "Verify no-mistakes signature in PR body"]
assert len(run) == 1, f"expected exactly one verify step, got {len(run)}"
open(sys.argv[2], "w").write(run[0])
PY

SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
ATTESTATION='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"deadbeef","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->'
PLACEHOLDER='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"...","steps":[...]} -->'

run_step() {
  PR_BODY=$1 PR_AUTHOR=tester PR_NUMBER=7 bash "$STEP" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
}

# 1. A body that quotes the placeholder before its real attestation still passes.
if run_step "$SIGNATURE

Evidence quoting the guidance:

    $PLACEHOLDER

## Pipeline

$ATTESTATION"; then
  pass "quoted placeholder before the real attestation does not shadow it"
else
  fail "quoted placeholder shadowed the real attestation: $(cat "$TMP_ROOT/err")"
fi

# 2. No attestation at all is still rejected.
if run_step "$SIGNATURE"; then
  fail "signature-only legacy body was accepted"
else
  grep -q 'attestation is missing or unparseable' "$TMP_ROOT/err" \
    || fail "legacy body rejected without the >= 1.46.0 guidance"
  pass "signature-only legacy body is rejected"
fi

# 3. A required step that is not completed is still rejected.
if run_step "$SIGNATURE

<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"deadbeef\",\"steps\":[{\"step\":\"review\",\"status\":\"completed\"},{\"step\":\"test\",\"status\":\"skipped\"}]} -->"; then
  fail "attestation with test=skipped was accepted"
else
  grep -q 'test=skipped, document=missing' "$TMP_ROOT/err" \
    || fail "skipped step rejected without naming the incomplete steps: $(cat "$TMP_ROOT/err")"
  pass "attestation with an incomplete required step is rejected"
fi

# 4. A body with no signature at all is rejected as not raised via no-mistakes.
if run_step "just a hand-written PR body"; then
  fail "unsigned body was accepted"
else
  grep -q 'was not raised through no-mistakes' "$TMP_ROOT/err" \
    || fail "unsigned body rejected with the wrong error"
  pass "body without the no-mistakes signature is rejected"
fi
