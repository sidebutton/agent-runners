# 18c-git-telemetry-timer.sh — recurring git-telemetry reconcile timer (SCRUM-513 §4).
#
# The capture half (base/14 stop hook) records each PR into jobs.prs at Stop, and the
# agent_se_review_merge step records the inline merge. This timer covers what a single Stop
# CANNOT see: merges done out-of-band (a human / a later run) and REVERTS (no playbook step
# reverts — this timer is the SOLE path for pr_reverted_at).
#
# It is the agent-side mirror of 18b-heartbeat-timer.sh: pull a worklist from the portal,
# resolve each PR's merge/revert state with the agent's OWN gh token (no checkout, no portal
# GitHub access — the portal makes zero GitHub calls), and post the outcome back.
#   GET  /api/agents/git-worklist   -> PRs needing a merge or revert check
#   POST /api/jobs/git-telemetry    -> { pr_url, repo_url, pr_number, state?, pr_merged_at?, pr_reverted_at? }
#
# Installed on ALL agents (server and serverless) — reconcile is independent of the SB server.

step "Step 18c: recurring git-telemetry reconcile timer (SCRUM-513)"

cat > /opt/sb-git-telemetry.sh <<'EOF'
#!/usr/bin/env bash
# Recurring git-telemetry reconcile — resolves merge/revert for the agent's open/merged PRs
# using its own gh token and reports them to the portal. Fully best-effort; never noisy.
set -uo pipefail
[ -f "$HOME/.agent-env" ] && . "$HOME/.agent-env"
TOK="${SIDEBUTTON_AGENT_TOKEN:-${AGENT_TOKEN:-}}"
NAME="${SIDEBUTTON_AGENT_NAME:-${AGENT_NAME:-}}"
URL="${PORTAL_URL:-https://sidebutton.com}"
LOG="${HOME}/.sidebutton/git-telemetry.log"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG" 2>/dev/null || true; }
[ -n "$TOK" ] && [ -n "$NAME" ] || exit 0
command -v gh  >/dev/null 2>&1 || { log "gh not installed — skipping"; exit 0; }
command -v jq  >/dev/null 2>&1 || exit 0

WORKLIST=$(curl -4 -sf "${URL}/api/agents/git-worklist" \
  -H "Authorization: Bearer ${TOK}" -H "X-Agent-Name: ${NAME}" \
  --connect-timeout 10 --max-time 30 2>/dev/null || echo '')
[ -z "$WORKLIST" ] && exit 0
COUNT=$(echo "$WORKLIST" | jq -r '.count // 0' 2>/dev/null || echo 0)
[ "${COUNT:-0}" = "0" ] && { log "worklist empty"; exit 0; }
log "worklist: $COUNT item(s)"

# owner/repo from a github PR url: https://github.com/<owner>/<repo>/pull/<n>
parse_slug() { echo "$1" | sed -nE 's#https?://[^/]+/([^/]+/[^/]+)/pull/[0-9]+.*#\1#p'; }

echo "$WORKLIST" | jq -c '.worklist[]' 2>/dev/null | while IFS= read -r item; do
  PR_URL=$(echo "$item"   | jq -r '.pr_url // ""')
  REPO_URL=$(echo "$item" | jq -r '.repo_url // ""')
  PR_NUM=$(echo "$item"   | jq -r '.pr_number // empty')
  NEEDS=$(echo "$item"    | jq -r '.needs // ""')
  [ -z "$PR_URL" ] && continue
  SLUG=$(parse_slug "$PR_URL")

  STATE=""; MERGED_AT=""; REVERTED_AT=""
  if [ "$NEEDS" = "merge" ]; then
    INFO=$(gh pr view "$PR_URL" --json state,mergedAt 2>/dev/null || echo '')
    [ -z "$INFO" ] && continue
    STATE=$(echo "$INFO" | jq -r '.state // ""')
    MERGED_AT=$(echo "$INFO" | jq -r '.mergedAt // ""')
    # Only report a definite merge; an still-open PR has nothing to reconcile.
    [ "$STATE" = "MERGED" ] || continue
  elif [ "$NEEDS" = "revert" ]; then
    INFO=$(gh pr view "$PR_URL" --json number,baseRefName,mergeCommit 2>/dev/null || echo '')
    [ -z "$INFO" ] && continue
    BASE=$(echo "$INFO"  | jq -r '.baseRefName // ""')
    MSHA=$(echo "$INFO"  | jq -r '.mergeCommit.oid // ""')
    NUM=$(echo "$INFO"   | jq -r '.number // empty')
    [ -z "$SLUG" ] && continue
    # Scan recent base-branch commits for a revert of this PR's merge commit / number.
    COMMITS=$(gh api "repos/${SLUG}/commits?sha=${BASE}&per_page=100" 2>/dev/null || echo '')
    [ -z "$COMMITS" ] && continue
    REVERTED_AT=$(echo "$COMMITS" | jq -r --arg sha "$MSHA" --arg num "#${NUM}" '
      [ .[]
        | .commit as $c
        | ($c.message // "") as $m
        | select(($m | ascii_downcase | contains("revert"))
                 and (($sha != "" and ($m | contains($sha))) or ($m | contains($num))))
        | $c.committer.date ] | .[0] // empty' 2>/dev/null || echo '')
    [ -z "$REVERTED_AT" ] && continue
    STATE="CLOSED"
  else
    continue
  fi

  PAYLOAD=$(jq -n --arg pr_url "$PR_URL" --arg repo_url "$REPO_URL" \
    --argjson num "${PR_NUM:-null}" --arg state "$STATE" \
    --arg merged "$MERGED_AT" --arg reverted "$REVERTED_AT" \
    '{pr_url:$pr_url, repo_url:$repo_url, pr_number:$num}
      + (if $state    != "" then {state:$state}            else {} end)
      + (if $merged   != "" then {pr_merged_at:$merged}    else {} end)
      + (if $reverted != "" then {pr_reverted_at:$reverted} else {} end)' 2>/dev/null || echo '')
  [ -z "$PAYLOAD" ] && continue

  curl -4 -sf -X POST "${URL}/api/jobs/git-telemetry" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOK}" -H "X-Agent-Name: ${NAME}" \
    -d "$PAYLOAD" --connect-timeout 10 --max-time 30 >/dev/null 2>&1 \
    && log "reconciled $PR_URL (${NEEDS}) merged=${MERGED_AT:-} reverted=${REVERTED_AT:-}" \
    || log "post failed for $PR_URL"
done
exit 0
EOF
chmod 0755 /opt/sb-git-telemetry.sh

cat > /etc/systemd/system/sb-git-telemetry.service <<'EOF'
[Unit]
Description=SideButton agent git-telemetry reconcile (merge/revert)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=agent
EnvironmentFile=/home/agent/.agent-env
ExecStart=/opt/sb-git-telemetry.sh
EOF

cat > /etc/systemd/system/sb-git-telemetry.timer <<'EOF'
[Unit]
Description=Run the SideButton git-telemetry reconcile shortly after boot, then every 30 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now sb-git-telemetry.timer >/dev/null 2>&1 \
  || log "WARN: failed to enable sb-git-telemetry.timer"
log "sb-git-telemetry timer enabled (boot+5min, then every 30min)"
