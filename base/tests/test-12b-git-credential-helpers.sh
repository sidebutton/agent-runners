#!/usr/bin/env bash
# base/tests/test-12b-git-credential-helpers.sh — regression guard for the per-host
# git credential helpers (base/12b-git-credential-helpers.sh).
#
# WHY THIS STEP EXISTS AT ALL: gitlab.com had NO credential helper while `glab` was
# already installed unconditionally (03b, SCRUM-1958), so every private GitLab clone
# died with "could not read Username for 'https://gitlab.com': terminal prompts
# disabled" — and because the helpers lived in 12-workspace.sh, which is policy-
# excluded from refresh-manifest.txt, no fix could ever reach an already-provisioned
# agent. The split + the manifest listing ARE the fix; both are asserted here.
#
# Contract under test:
#   * WIRING — sourced by run.sh exactly once, immediately AFTER 12-workspace.sh,
#     and LISTED in refresh-manifest.txt (the carve-out that reaches the live fleet).
#   * NO CREDENTIAL AT REST — the step must never write a token into .gitconfig; every
#     helper sources ~/.agent-env at CALL time. Asserted structurally (no bare token
#     env-var interpolation outside a single-quoted helper body) and behaviourally.
#   * BEHAVIOUR — executed for real against a sandbox HOME, then driven through
#     `git credential fill`: gitlab.com resolves to username=oauth2 + the CURRENT
#     token; a ROTATED token is picked up with no re-auth; an ABSENT token makes the
#     helper DECLINE (never blank credentials); repeated runs stay idempotent.
#
# Hermetic: no network, no root, writes only inside a mktemp sandbox. Uses the real
# `git` binary (present on every runner). The github.com helper is NOT exercised — it
# execs /usr/bin/gh, which a generic CI runner does not have; its wiring is asserted
# textually instead.
# Run: bash base/tests/test-12b-git-credential-helpers.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
STEP="$BASE/12b-git-credential-helpers.sh"
RUNSH="$BASE/run.sh"
MANIFEST="$BASE/refresh-manifest.txt"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# ── 0. step validity ─────────────────────────────────────────────────────────
[ -f "$STEP" ] && ok "base/12b-git-credential-helpers.sh exists" || { bad "step missing: $STEP"; exit 1; }
bash -n "$STEP" && ok "bash -n: 12b-git-credential-helpers.sh" || bad "bash -n failed on the step"

# ── 1. wiring into run.sh: once, top level, right after 12 ───────────────────
n_src="$(grep -c '12b-git-credential-helpers\.sh' "$RUNSH")"
[ "$n_src" = "1" ] && ok "run.sh sources 12b exactly once" || bad "run.sh sources 12b $n_src times (want 1)"

l_12="$(grep -n '^\. "\$BASE_DIR/12-workspace\.sh"' "$RUNSH" | cut -d: -f1)"
l_12b="$(grep -n '^\. "\$BASE_DIR/12b-git-credential-helpers\.sh"' "$RUNSH" | cut -d: -f1)"
if [ -n "$l_12" ] && [ -n "$l_12b" ] && [ "$l_12b" -gt "$l_12" ]; then
  ok "order: 12-workspace ($l_12) → 12b-git-credential-helpers ($l_12b), top level"
else
  bad "12b is not sourced at top level after 12-workspace (12=$l_12 12b=$l_12b)"
fi

# ── 2. THE fleet-delivery invariant: 12b listed, 12 still excluded ───────────
if grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | grep -qx '12b-git-credential-helpers.sh'; then
  ok "12b IS listed in refresh-manifest.txt (reaches already-provisioned agents)"
else
  bad "12b missing from refresh-manifest.txt — a helper fix would never reach the live fleet"
fi
if grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | grep -qx '12-workspace.sh'; then
  bad "12-workspace.sh is listed in refresh-manifest.txt — it is one-time setup, not refresh-safe"
else
  ok "12-workspace.sh stays excluded from the manifest"
fi

# The helpers must NOT have been left behind in 12 as well (double-write drift).
if sed 's/#.*//' "$BASE/12-workspace.sh" | grep -q 'credential\..*helper'; then
  bad "12-workspace.sh still writes a credential helper — must live only in 12b"
else
  ok "12-workspace.sh no longer writes credential helpers (single source of truth)"
fi

# ── 3. every host we claim to serve is actually wired ────────────────────────
for host in github.com gitlab.com bitbucket.org; do
  if grep -q "$host" "$STEP"; then ok "helper wired for $host"; else bad "no helper for $host"; fi
done

# ── 4. no credential at rest ─────────────────────────────────────────────────
# Each helper body is single-quoted-ish and resolved at call time; the step itself
# must never `git config` a raw token value.
if sed 's/#.*//' "$STEP" | grep -E 'git config' | grep -qE '\$\{?(GITLAB_TOKEN|GH_TOKEN|BITBUCKET_API_TOKEN|SIDEBUTTON_DEFAULT_REGISTRY_TOKEN)\}?'; then
  bad "step writes a token value into .gitconfig — helpers must resolve at call time"
else
  ok "no token value is ever written into .gitconfig"
fi
if grep -q 'agent-env' "$STEP"; then
  ok "helpers source ~/.agent-env (call-time resolution)"
else
  bad "step never references ~/.agent-env — call-time resolution is the whole contract"
fi

# ── 5. behaviour: execute the step, drive it through git credential fill ─────
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home"

run_step() {
  ( set -euo pipefail
    export AGENT_USER="$(id -un)" AGENT_HOME="$SANDBOX/home" BASE_DIR="$BASE" LOG_FILE="$SANDBOX/log"
    set -a; [ -f "$SANDBOX/home/.agent-env" ] && . "$SANDBOX/home/.agent-env"; set +a
    . "$BASE/lib.sh"
    . "$STEP"
  ) >/dev/null 2>&1
}
fill() {
  printf 'protocol=https\nhost=%s\n\n' "$1" \
    | HOME="$SANDBOX/home" GIT_CONFIG_GLOBAL="$SANDBOX/home/.gitconfig" GIT_TERMINAL_PROMPT=0 \
      git credential fill 2>/dev/null
}

printf 'GITLAB_TOKEN=glpat-FIRST\n' > "$SANDBOX/home/.agent-env"
if run_step; then ok "step runs clean under the refresh contract (set -euo pipefail)"; else bad "step failed under set -euo pipefail"; fi

out="$(fill gitlab.com)"
if grep -qx 'username=oauth2' <<<"$out" && grep -qx 'password=glpat-FIRST' <<<"$out"; then
  ok "gitlab.com resolves to username=oauth2 + the current token"
else
  bad "gitlab.com did not resolve as expected: $(tr '\n' ' ' <<<"$out")"
fi

# Rotation: change the file only — no re-auth, no reboot, no re-run of the step.
printf 'GITLAB_TOKEN=glpat-ROTATED\n' > "$SANDBOX/home/.agent-env"
if grep -qx 'password=glpat-ROTATED' <<<"$(fill gitlab.com)"; then
  ok "a ROTATED token is served immediately (no re-auth, no reboot)"
else
  bad "rotation not picked up — helper is not resolving at call time"
fi

# Absent token: decline, never blank credentials (which would 401 confusingly).
printf '# no token\n' > "$SANDBOX/home/.agent-env"
out="$(fill gitlab.com)"
if grep -qE '^password=' <<<"$out"; then
  bad "helper emitted a credential with no token set: $(tr '\n' ' ' <<<"$out")"
else
  ok "with no token the helper declines (no blank credentials)"
fi

# Idempotency: the --replace-all/--add pair must not accumulate entries.
printf 'GITLAB_TOKEN=glpat-FIRST\n' > "$SANDBOX/home/.agent-env"
run_step; run_step
n="$(git config -f "$SANDBOX/home/.gitconfig" --get-all credential.https://gitlab.com.helper | grep -c .)"
[ "$n" = "1" ] && ok "re-running keeps exactly one gitlab.com helper (idempotent)" \
               || bad "gitlab.com helper accumulated $n entries across runs"

echo
[ "$fail" = 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
