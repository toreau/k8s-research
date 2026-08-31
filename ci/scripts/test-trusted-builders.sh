#!/usr/bin/env bash
# test-trusted-builders.sh — fail-closed validation matrix for the trust-file
# parser (ci/scripts/trusted-builders.rb). PASS cases must parse; FAIL cases
# must exit non-zero. No production effect.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARSER="$ROOT/ci/scripts/trusted-builders.rb"
VALID_SHA="373df7517487bd20ac55a0986926677c0ddcbcf6"
VALID_WF="toreau/gh-workflows/.github/workflows/container-build-attest.yml"

pass_count=0
fail_count=0

run_parser() {
  local name="$1" expect="$2" f="$3"
  local out rc
  out=$(TRUSTED_BUILDERS="$f" ruby "$PARSER" 2>&1)
  rc=$?
  if { [ "$expect" = OK ] && [ $rc -eq 0 ]; } || { [ "$expect" = FAIL ] && [ $rc -ne 0 ]; }; then
    pass_count=$((pass_count + 1))
    echo "PASS [$expect] $name"
  else
    fail_count=$((fail_count + 1))
    echo "FAIL [want $expect] $name (rc=$rc)"
    echo "  $out" | head -2
  fi
}

mkcase() {
  # mkcase <name> <expect> <<'YAML' ... YAML
  local name="$1" expect="$2"
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/ci"
  cat > "$tmp/ci/trusted-builders.yaml"
  run_parser "$name" "$expect" "$tmp/ci/trusted-builders.yaml"
  rm -rf "$tmp"
}

echo "## PASS"
mkcase "valid v1" OK <<YAML
version: 1
builders:
  container:
    workflow: $VALID_WF
    revisions:
      - sha: $VALID_SHA
YAML
mkcase "multiple valid unique revisions" OK <<YAML
version: 1
builders:
  container:
    workflow: $VALID_WF
    revisions:
      - sha: $VALID_SHA
      - sha: 1111111111111111111111111111111111111111
YAML

echo "## FAIL"
mkdir -p /tmp/tb-missing && rm -f /tmp/tb-missing/ci/trusted-builders.yaml
run_parser "missing file" FAIL "/tmp/tb-missing/ci/trusted-builders.yaml"
mkcase "malformed YAML" FAIL <<'YAML'
version: 1
builders: [unclosed
YAML
mkcase "wrong version" FAIL <<YAML
version: 2
builders:
  container:
    workflow: $VALID_WF
    revisions:
      - sha: $VALID_SHA
YAML
mkcase "missing version" FAIL <<YAML
builders:
  container:
    workflow: $VALID_WF
    revisions:
      - sha: $VALID_SHA
YAML
mkcase "missing builder" FAIL <<YAML
version: 1
builders: {}
YAML
mkcase "missing workflow" FAIL <<YAML
version: 1
builders:
  container:
    revisions:
      - sha: $VALID_SHA
YAML
mkcase "empty revisions" FAIL <<YAML
version: 1
builders:
  container:
    workflow: $VALID_WF
    revisions: []
YAML
mkcase "malformed SHA" FAIL <<YAML
version: 1
builders:
  container:
    workflow: $VALID_WF
    revisions:
      - sha: zzzz
YAML
mkcase "abbreviated SHA" FAIL <<YAML
version: 1
builders:
  container:
    workflow: $VALID_WF
    revisions:
      - sha: 373df751
YAML
mkcase "uppercase SHA" FAIL <<YAML
version: 1
builders:
  container:
    workflow: $VALID_WF
    revisions:
      - sha: 373DF7517487BD20AC55A0986926677C0DDCBCF6
YAML
mkcase "duplicate SHA" FAIL <<YAML
version: 1
builders:
  container:
    workflow: $VALID_WF
    revisions:
      - sha: $VALID_SHA
      - sha: $VALID_SHA
YAML
mkcase "workflow with @ref" FAIL <<YAML
version: 1
builders:
  container:
    workflow: toreau/gh-workflows/.github/workflows/container-build-attest.yml@deadbeef
    revisions:
      - sha: $VALID_SHA
YAML
mkcase "workflow with whitespace" FAIL <<YAML
version: 1
builders:
  container:
    workflow: "toreau/gh-workflows/.github/workflows/x y.yml"
    revisions:
      - sha: $VALID_SHA
YAML
mkcase "workflow wrong shape" FAIL <<YAML
version: 1
builders:
  container:
    workflow: toreau/container-build-attest.yml
    revisions:
      - sha: $VALID_SHA
YAML

echo
echo "RESULT: pass=$pass_count fail=$fail_count"
[ "$fail_count" -eq 0 ]
