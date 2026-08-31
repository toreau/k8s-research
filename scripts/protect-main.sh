#!/usr/bin/env bash
# protect-main.sh — protect k8s-research `main` with an active ruleset.
#
# Model (single-owner):
#   - direct push to main is NOT an accepted path
#   - all changes go through a pull request
#   - repository admins have an explicit `pull_request`-only bypass: they may
#     bypass PR review at merge via a PR, but never push directly to main.
#   This is NOT two-party review; privileged PR-only bypass is a documented
#   residual risk (and disabling the ruleset itself is a control-plane
#   compromise the rules cannot prevent).
#
# Idempotent: creates the ruleset if absent, updates it if present. It only
# manages the repository-level `main-protection` branch ruleset and never
# deletes other rulesets. Fails closed on GitHub API errors.
#
# Required checks are the ACTUAL check contexts observed on PRs
# (verified 2026-08-31 from PR #23 head check-runs):
#   - validate-apps / validate
#   - validate-argocd / validate
#   - gate-pr
# NOTE: the historical classic-protection context "gate-pr / gate" never
# matched a real check run; the actual gate-pr job reports as "gate-pr".
set -euo pipefail
repo="toreau/k8s-research"
name="main-protection"

body() {
  jq -n --arg n "$name" '{name:$n, target:"branch", enforcement:"active",
    bypass_actors:[{actor_id:2, actor_type:"RepositoryRole", bypass_mode:"pull_request"}],
    conditions:{ref_name:{include:["refs/heads/main"], exclude:[]}},
    rules:[
      {type:"deletion"},
      {type:"non_fast_forward"},
      {type:"pull_request", parameters:{required_approving_review_count:1,
        dismiss_stale_reviews_on_push:true, require_code_owner_review:false,
        require_last_push_approval:true, required_review_thread_resolution:true}},
      {type:"required_status_checks", parameters:{strict_required_status_checks_policy:true,
        do_not_enforce_on_create:false,
        required_status_checks:[
          {context:"validate-apps / validate"},
          {context:"validate-argocd / validate"},
          {context:"gate-pr"}
        ]}}
    ]}'
}

existing=$(gh api "repos/${repo}/rulesets" --jq --arg n "$name" \
  '.[] | select(.name==$n and .target=="branch") | .id' 2>/dev/null || true)

if [ -n "$existing" ]; then
  echo "updating ruleset $existing ($name) on $repo"
  body | gh api "repos/${repo}/rulesets/${existing}" --method PUT --input - >/dev/null
else
  echo "creating ruleset $name on $repo"
  body | gh api "repos/${repo}/rulesets" --method POST --input - >/dev/null
fi

echo "protection applied (verify: gh api repos/${repo}/rulesets; rules/branches/main)"
