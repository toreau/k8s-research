#!/usr/bin/env bash
set -euo pipefail
repo="toreau/k8s-research"
branch="main"
body=$(cat <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "validate-apps / validate",
      "validate-argocd / validate",
      "gate-pr / gate"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": false
}
JSON
)
gh api -X PUT "repos/${repo}/branches/${branch}/protection" --input - <<<"$body"
echo "protection applied (verify: gh api repos/${repo}/branches/${branch}/protection)"
