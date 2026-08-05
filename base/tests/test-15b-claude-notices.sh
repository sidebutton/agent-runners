#!/usr/bin/env bash
# base/tests/test-15b-claude-notices.sh — guard for the first-run NOTICE seeding in
# base/15b-claude-onboarding.sh (2026-08-05).
#
# Why this exists: a freshly installed Claude Code has no record of what this "user"
# has already seen, so its first interactive launch renders the "What's new" panel and
# the launch/upsell notices. On an agent VM those cover most of the window an operator
# watches over VNC/RDP and nothing on the box will ever dismiss them — no human drives
# it. 15b already owned ~/.claude.json (onboarding + folder trust), so the seen-state
# rides the same merge.
#
# Acceptance:
#   AC1 — a fresh ~/.claude.json gets the onboarding/trust keys AND the notice keys,
#         with the version stamps set to the INSTALLED CLI version (not a constant)
#   AC2 — a counter Claude Code already raised past the seed is never REWOUND
#   AC3 — unrelated existing state (mcpServers, other projects) survives the merge
#   AC4 — an unresolvable `claude --version` skips BOTH version stamps rather than
#         writing a wrong one, and still seeds everything else
#   AC5 — re-running is idempotent (the refresh path runs it on every fingerprint bump)
#   AC6 — the step is listed in refresh-manifest.txt, or the stamps go stale on the
#         first CLI upgrade and the panel returns
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-15b-claude-notices.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
STEP="$ROOT/base/15b-claude-onboarding.sh"
MANIFEST="$ROOT/base/refresh-manifest.txt"

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

[ -f "$STEP" ] || { bad "base/15b-claude-onboarding.sh missing"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fake `claude` on PATH so the step resolves a deterministic version. Matches the
# real CLI's format: "<semver> (Claude Code)".
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
# PATH the step runs under: the fake bin plus the SYSTEM dirs only. Deliberately does
# NOT inherit $PATH — a developer's real `claude` (nvm/homebrew/…) would otherwise be
# found after the fake one is removed, and the "unresolvable version" case (AC4) would
# silently pass against a real CLI instead of testing anything. Mirrors the root PATH
# sb-self-update exports on the VM.
SANDBOX_PATH="$FAKEBIN:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
make_claude() { printf '#!/usr/bin/env bash\necho "%s"\n' "$1" > "$FAKEBIN/claude"; chmod +x "$FAKEBIN/claude"; }
drop_claude() { rm -f "$FAKEBIN/claude"; }

# Run the step against a home dir seeded with $1 (JSON), returning the merged file.
# Stubs step()/log() (lib.sh is not sourced) and chowns to the CURRENT user so the
# step's chown succeeds unprivileged.
run_step() {
  local seed="$1" home="$WORK/home"
  rm -rf "$home"; mkdir -p "$home"
  [ "$seed" = "-" ] || printf '%s' "$seed" > "$home/.claude.json"
  (
    set +e
    export AGENT_HOME="$home" AGENT_USER="$(id -un)" PATH="$SANDBOX_PATH"
    step() { :; }
    log()  { :; }
    # shellcheck source=/dev/null
    . "$STEP"
  ) >/dev/null 2>&1
  cat "$home/.claude.json"
}

j() { jq -r "$1" <<<"$2"; }

# ── AC1 — fresh file: onboarding + trust + notices, version stamps from the CLI ──
make_claude "2.1.222 (Claude Code)"
out="$(run_step -)"

[ "$(j '.hasCompletedOnboarding' "$out")" = "true" ] \
  && ok "AC1 hasCompletedOnboarding seeded" || bad "AC1 hasCompletedOnboarding not seeded"
[ "$(j '.projects | keys | length' "$out")" -ge 3 ] \
  && ok "AC1 folder trust still seeded (regression guard on the original behaviour)" \
  || bad "AC1 folder-trust seeding regressed"
[ "$(j '.lastReleaseNotesSeen' "$out")" = "2.1.222" ] \
  && ok "AC1 lastReleaseNotesSeen stamped with the INSTALLED version" \
  || bad "AC1 lastReleaseNotesSeen = $(j '.lastReleaseNotesSeen' "$out") (want 2.1.222)"
[ "$(j '.lastOnboardingVersion' "$out")" = "2.1.222" ] \
  && ok "AC1 lastOnboardingVersion stamped" || bad "AC1 lastOnboardingVersion not stamped"
[ "$(j '.hasSeenTasksHint' "$out")" = "true" ] \
  && ok "AC1 hasSeenTasksHint seeded" || bad "AC1 hasSeenTasksHint not seeded"
for k in subscriptionNoticeCount fullscreenUpsellSeenCount passesUpsellSeenCount remoteControlUpsellSeenCount; do
  [ "$(j ".$k" "$out")" = "99" ] && ok "AC1 $k raised" || bad "AC1 $k = $(j ".$k" "$out") (want 99)"
done

# ── AC2 — never rewind a counter Claude Code itself raised past the seed ──
out="$(run_step '{"fullscreenUpsellSeenCount": 500, "passesUpsellSeenCount": 2}')"
[ "$(j '.fullscreenUpsellSeenCount' "$out")" = "500" ] \
  && ok "AC2 an existing HIGHER count is preserved (max, not overwrite)" \
  || bad "AC2 rewound a higher count to $(j '.fullscreenUpsellSeenCount' "$out")"
[ "$(j '.passesUpsellSeenCount' "$out")" = "99" ] \
  && ok "AC2 an existing LOWER count is raised" || bad "AC2 lower count not raised"

# ── AC3 — unrelated stored state survives ──
out="$(run_step '{"mcpServers":{"sidebutton":{"command":"sb"}},"projects":{"/other":{"hasTrustDialogAccepted":true}},"oauthAccount":{"emailAddress":"a@b.c"}}')"
[ "$(j '.mcpServers.sidebutton.command' "$out")" = "sb" ] \
  && ok "AC3 mcpServers (written by step 15) preserved" || bad "AC3 mcpServers clobbered"
[ "$(j '.projects["/other"].hasTrustDialogAccepted' "$out")" = "true" ] \
  && ok "AC3 a pre-existing project entry preserved" || bad "AC3 pre-existing project clobbered"
[ "$(j '.oauthAccount.emailAddress' "$out")" = "a@b.c" ] \
  && ok "AC3 unrelated account state preserved" || bad "AC3 unrelated account state clobbered"

# ── AC4 — unresolvable version: skip BOTH stamps, seed everything else ──
drop_claude
out="$(run_step -)"
[ "$(j 'has("lastReleaseNotesSeen")' "$out")" = "false" ] \
  && ok "AC4 no release-notes stamp written when the version is unresolvable" \
  || bad "AC4 wrote a release-notes stamp without a version: $(j '.lastReleaseNotesSeen' "$out")"
[ "$(j 'has("lastOnboardingVersion")' "$out")" = "false" ] \
  && ok "AC4 no onboarding-version stamp written either" || bad "AC4 wrote an onboarding stamp"
[ "$(j '.hasCompletedOnboarding' "$out")" = "true" ] \
  && ok "AC4 the non-version seeding still happened" || bad "AC4 lost the non-version seeding"
[ "$(j '.fullscreenUpsellSeenCount' "$out")" = "99" ] \
  && ok "AC4 counters still raised" || bad "AC4 counters not raised"

# ── AC5 — idempotent: the refresh path re-runs this on every fingerprint bump ──
make_claude "2.1.222 (Claude Code)"
home="$WORK/home"
first="$(run_step -)"
(
  set +e
  export AGENT_HOME="$home" AGENT_USER="$(id -un)" PATH="$FAKEBIN:$PATH"
  step() { :; }; log() { :; }
  # shellcheck source=/dev/null
  . "$STEP"
) >/dev/null 2>&1
second="$(cat "$home/.claude.json")"
[ "$(jq -S . <<<"$first")" = "$(jq -S . <<<"$second")" ] \
  && ok "AC5 a second run is a byte-identical no-op" || bad "AC5 not idempotent"

# ── AC6 — listed in the refresh manifest, or the stamps go stale on the next upgrade ──
if [ -r "$MANIFEST" ]; then
  sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "$MANIFEST" | awk 'NF' \
    | grep -qx '15b-claude-onboarding.sh' \
    && ok "AC6 15b is listed in refresh-manifest.txt (reaches existing agents)" \
    || bad "AC6 15b missing from refresh-manifest.txt — stamps would go stale on the first CLI upgrade"
else
  bad "AC6 refresh-manifest.txt unreadable"
fi

echo
[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
