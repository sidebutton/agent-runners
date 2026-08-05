# 15b-claude-onboarding.sh — pre-complete Claude Code's first-run prompts AND its
# first-run notices (release notes / upsells), so an agent's window is work, not chrome.
#
# Claude Code gates the first interactive run on two things in ~/.claude.json:
#   1. onboarding (theme picker)  — `hasCompletedOnboarding`
#   2. per-folder trust           — `projects[<dir>].hasTrustDialogAccepted`
#      ("Is this a project you trust?" on first entry to a directory)
# 07 installs the CLI and 15 runs `claude mcp add` (non-interactive, so
# provisioning never blocks), but neither marks these done. The first time
# anything launches claude INTERACTIVELY — e.g. the agent_pull_repos ops
# workflow runs `claude --dangerously-skip-permissions "<prompt>"` in a visible
# terminal — it stops at the theme picker, then (once past that) at the trust
# prompt for ~/workspace. --dangerously-skip-permissions bypasses tool prompts
# but NOT these first-run gates on this Claude Code version. Seed both so agents
# start straight into work unattended (auth is satisfied by ANTHROPIC_API_KEY /
# GH_TOKEN in ~/.agent-env).
#
# ── First-run NOTICES (2026-08-05) ────────────────────────────────────────────
# Getting past onboarding is not enough: a freshly installed Claude Code has no
# record of what this "user" has already seen, so its first interactive launch
# also renders the "What's new" release-notes panel and the launch/upsell notices
# — which on an agent VM cover most of the window an operator is watching over
# VNC/RDP, and which nothing on the box will ever dismiss (no human drives it).
#
# The seen-state lives in the SAME ~/.claude.json this step already owns, so the
# keys below ride the existing merge. Each is a real key written by Claude Code
# itself (verified against the shipped 2.1.x CLI):
#
#   lastReleaseNotesSeen     version string; the "What's new" panel renders while
#                            it differs from the RUNNING version, so it is stamped
#                            with the INSTALLED version, not a constant.
#   lastOnboardingVersion    pairs with hasCompletedOnboarding — a version-keyed
#                            re-onboarding prompt has nothing to re-ask.
#   *SeenCount / *NoticeCount  impression counters the notices gate on; raised past
#                            any plausible cap, and only ever RAISED (see below).
#   hasSeenTasksHint         one-shot inline hint, same rationale.
#
# Deliberately NOT seeded — `announcementImpressions`, `tipsHistory` and
# `tipLifetimeShownCounts` are keyed by campaign/tip IDs minted upstream, so a
# future ID cannot be pre-dismissed by construction. They are per-notice and small;
# the panel-sized offenders are the ones above. If they ever become the problem,
# the lever is CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 in ~/.agent-env (it stops
# the remote fetch that mints them) — not more key-guessing here.
#
# Counters are raised with a max() so a re-run can never REWIND a real count that
# Claude Code itself incremented past the seed. The version stamps are absolute:
# re-stamping is the entire point after a CLI upgrade, which is why this step is
# in refresh-manifest.txt (see the carve-out note there) — a provision-only seed
# would go stale the first time Claude Code is upgraded and the panel would return.
#
# Not gated by SKIP_SIDEBUTTON_SERVER — these gates affect every variant that
# ships Claude Code. jq is installed by 02-system; the merge preserves the
# mcpServers entry 15 wrote and is safe to re-run. Trust is seeded for the
# standard agent work dirs (~/workspace, ~/ops, ~/oss).

step "Step 15b/16: Pre-complete Claude Code onboarding, folder trust + first-run notices"
CLAUDE_JSON="${AGENT_HOME}/.claude.json"
[ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"

# The INSTALLED CLI version drives the two version-keyed stamps. Resolve it from the
# CLI itself rather than pinning a constant: a constant would be wrong for every box
# provisioned after the next release, and wrong again after every upgrade. `claude
# --version` prints e.g. "2.1.222 (Claude Code)"; take the semver token only.
# Unresolvable (claude not on root's PATH during a refresh, or a changed --version
# format) ⇒ leave BOTH stamps untouched rather than write a wrong one: a missing
# stamp costs one panel, a wrong stamp is indistinguishable from a stale one and
# would keep costing it.
CLAUDE_VER="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
[ -n "$CLAUDE_VER" ] || log "WARN: could not resolve the Claude Code version — release-notes/onboarding stamps skipped"

# Raised (never lowered) impression counters. 99 is far past any shipped cap while
# staying a plausible integer, so a future cap increase does not silently un-dismiss.
NOTICE_SEEN_COUNT=99

tmp="$(mktemp)"
if jq \
      --arg h "$AGENT_HOME" \
      --arg ver "$CLAUDE_VER" \
      --argjson seen "$NOTICE_SEEN_COUNT" '
      # raise(key) — set key to max(existing, $seen); never rewinds a real count.
      # `| numbers` is load-bearing, not defensive noise: jq orders numbers BEFORE
      # strings, so a non-number left in the file (hand-edit, corruption, a future
      # format change) would win the max and be written back — leaving the notice
      # both un-dismissed AND still non-numeric. Coercing a non-number to 0 makes the
      # seed win instead, so the key is always a number afterwards.
      def raise(k): .[k] = ([((.[k] | numbers) // 0), $seen] | max);

        . + {hasCompletedOnboarding: true, hasCompletedProjectOnboarding: true, theme: "dark"}
      | .projects = (.projects // {})
      | .projects[$h + "/workspace"] = ((.projects[$h + "/workspace"] // {}) + {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true})
      | .projects[$h + "/ops"]       = ((.projects[$h + "/ops"] // {})       + {hasTrustDialogAccepted: true})
      | .projects[$h + "/oss"]       = ((.projects[$h + "/oss"] // {})       + {hasTrustDialogAccepted: true})

      # First-run notices. The version stamps are skipped wholesale when the CLI
      # version could not be resolved (empty $ver) — see the WARN above.
      | (if $ver == "" then . else
           . + {lastReleaseNotesSeen: $ver, lastOnboardingVersion: $ver}
         end)
      | .hasSeenTasksHint = true
      | raise("subscriptionNoticeCount")
      | raise("fullscreenUpsellSeenCount")
      | raise("passesUpsellSeenCount")
      | raise("remoteControlUpsellSeenCount")
    ' "$CLAUDE_JSON" > "$tmp" 2>/dev/null; then
  mv "$tmp" "$CLAUDE_JSON"
else
  rm -f "$tmp"
  log "WARN: could not seed Claude Code onboarding/trust/notice flags in $CLAUDE_JSON"
fi
chown "${AGENT_USER}:${AGENT_USER}" "$CLAUDE_JSON"
chmod 600 "$CLAUDE_JSON"
log "claude onboarding + folder trust pre-completed (~/workspace, ~/ops, ~/oss); first-run notices dismissed${CLAUDE_VER:+ (release notes ≤ ${CLAUDE_VER})}"
