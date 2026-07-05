#!/usr/bin/env bash
# base/tests/test-14c-run-identity.sh — regression guard for the AUTH-4 (SCRUM-1629,
# PROVIDER-AUTH-VISIBILITY.md §7) per-run auth-identity stamp in 14-claude-stop-hook.sh.
#
# detect_run_identity() echoes a compact NON-SECRET {method, id, base_host?} naming the auth identity
# that actually served a run — the subscription / key / cloud principal that spent the quota — so the
# portal can attribute burn (jobs.auth_identity) and roll up usage-by-identity. It parallels
# detect_effective_route (test-14b) and rides the SAME /api/jobs/usage POST, INSIDE `usage`. This test
# proves: the subscription / api_key / gateway / bedrock / vertex identities; foundry / CCR / no-auth
# omit (empty stamp, never a wrong one); the §4.3 fingerprint shape (first-6 + … + last-4, short → …last-2)
# reproduces the reporter's fingerprint(); no raw token / cloud secret ever leaks into the stamp; and the
# stamp is merged into `usage` on the usage POST but NOT onto the step-complete POST (which carries no usage).
#
# Pure bash + jq (both present on the runner). Run: bash base/tests/test-14c-run-identity.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
HOOK="$BASE/14-claude-stop-hook.sh"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }
skip() { printf 'skip - %s\n' "$1"; }

# ── 0. installer + generated hook stay syntactically valid ───────────────────────────────────────
bash -n "$HOOK" && ok "bash -n: 14-claude-stop-hook.sh" || bad "bash -n failed on the hook"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
awk "/cat > .*claude-stop-hook.sh.*<<'HOOKEOF'/{f=1;next} /^HOOKEOF\$/{f=0} f" "$HOOK" > "$TMP/claude-stop-hook.sh"
bash -n "$TMP/claude-stop-hook.sh" && ok "bash -n: generated claude-stop-hook.sh" || bad "bash -n failed on generated hook"

# The /api/jobs/usage payload must merge the run identity INTO `usage` (the portal reads it there,
# alongside the route triple). Absent this merge, the portal never sees the stamp.
grep -qF 'auth_identity:$ident' "$TMP/claude-stop-hook.sh" \
  && ok "usage payload merges auth_identity into usage" \
  || bad "usage payload is missing the auth_identity merge (portal would never see the stamp)"
grep -q 'detect_run_identity' "$TMP/claude-stop-hook.sh" \
  && ok "detect_run_identity is wired into the hook" \
  || bad "detect_run_identity is missing from the hook"
# It must NOT ride the step-complete POST — that carries no `usage`, so a stamp there is meaningless and
# a partial object could clobber. Only ONE call site (the usage payload build) may reference $ident.
IDENT_REFS=$(grep -c '\$ident' "$TMP/claude-stop-hook.sh" || true)
[ "${IDENT_REFS:-0}" -le 2 ] \
  && ok "auth_identity confined to the usage payload (\$ident refs=${IDENT_REFS})" \
  || bad "auth_identity leaked beyond the usage payload (\$ident refs=${IDENT_REFS})"

# ── Extract the pure detector (+ its fp_token helper) and drive it across the identity matrix ─────
awk '/^fp_token\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$TMP/claude-stop-hook.sh"  > "$TMP/ident.sh"
awk '/^detect_run_identity\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$TMP/claude-stop-hook.sh" >> "$TMP/ident.sh"
grep -q '^detect_run_identity() {' "$TMP/ident.sh" \
  && ok "extracted detect_run_identity from the hook heredoc" \
  || bad "could not extract detect_run_identity from the hook"

if command -v jq >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$TMP/ident.sh"
  field() { printf '%s' "$1" | jq -r ".$2 // \"\"" 2>/dev/null || echo "ERR"; }
  # A fixture HOME whose ~/.claude.json carries a subscription oauthAccount.
  export HOME="$TMP/home"; mkdir -p "$HOME"
  printf '%s' '{"oauthAccount":{"emailAddress":"op1@company.com","organizationName":"Company"}}' > "$HOME/.claude.json"

  # 1. Subscription — direct Anthropic, NO token in effect → run-as email (AC1).
  S="$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY; detect_run_identity)"
  [ "$(field "$S" method)" = "subscription" ]       && ok "subscription: method=subscription"        || bad "subscription method: $(field "$S" method)"
  [ "$(field "$S" id)" = "op1@company.com" ]        && ok "subscription: id=oauthAccount email"       || bad "subscription id: $(field "$S" id)"

  # 2. API key — a token in effect, no gateway base URL → method=api_key, id=FINGERPRINT (§4.3).
  A="$(unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL; ANTHROPIC_API_KEY='sk-ant-api03-ABCDEFxyz1234wxyz' detect_run_identity)"
  [ "$(field "$A" method)" = "api_key" ]            && ok "api_key: method=api_key"                   || bad "api_key method: $(field "$A" method)"
  [ "$(field "$A" id)" = "sk-ant…wxyz" ]            && ok "api_key: id=first6…last4 fingerprint"      || bad "api_key id: $(field "$A" id)"
  case "$A" in *sk-ant-api03-ABCDEFxyz1234wxyz*) bad "api_key: the RAW token leaked into the stamp" ;; *) ok "api_key: no raw token in the stamp" ;; esac

  # 3. Gateway — token + a NON-LOCAL ANTHROPIC_BASE_URL → method=gateway + base_host, id=fingerprint.
  G="$(unset ANTHROPIC_API_KEY; ANTHROPIC_AUTH_TOKEN='sk-kimi-secrettokenABCD' ANTHROPIC_BASE_URL='https://api.kimi.com/v1' detect_run_identity)"
  [ "$(field "$G" method)" = "gateway" ]            && ok "gateway: method=gateway"                   || bad "gateway method: $(field "$G" method)"
  [ "$(field "$G" base_host)" = "api.kimi.com" ]    && ok "gateway: base_host=endpoint host"          || bad "gateway base_host: $(field "$G" base_host)"
  [ "$(field "$G" id)" = "sk-kim…ABCD" ]            && ok "gateway: id=fingerprint of the auth token" || bad "gateway id: $(field "$G" id)"

  # 4. Bedrock — flag + AWS_PROFILE, no token → method=bedrock, id=profile (best-effort, no `aws sts`).
  B="$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL; CLAUDE_CODE_USE_BEDROCK=1 AWS_PROFILE='gs-prod' AWS_SECRET_ACCESS_KEY='wJalr-SECRET' detect_run_identity)"
  [ "$(field "$B" method)" = "bedrock" ]            && ok "bedrock: method=bedrock"                   || bad "bedrock method: $(field "$B" method)"
  [ "$(field "$B" id)" = "gs-prod" ]                && ok "bedrock: id=AWS_PROFILE"                    || bad "bedrock id: $(field "$B" id)"
  case "$B" in *wJalr-SECRET*) bad "bedrock: an AWS credential leaked into the stamp" ;; *) ok "bedrock: no AWS secret in the stamp" ;; esac

  # 5. Vertex — flag + project id from env → method=vertex, id=project (no `gcloud` at Stop).
  V="$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL; CLAUDE_CODE_USE_VERTEX=1 ANTHROPIC_VERTEX_PROJECT_ID='gs-vertex-1' detect_run_identity)"
  [ "$(field "$V" method)" = "vertex" ]             && ok "vertex: method=vertex"                     || bad "vertex method: $(field "$V" method)"
  [ "$(field "$V" id)" = "gs-vertex-1" ]            && ok "vertex: id=Vertex project"                 || bad "vertex id: $(field "$V" id)"

  # 6. Foundry with no principal → OMIT (empty stamp; a method with no id is worse than none).
  FD="$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL; CLAUDE_CODE_USE_FOUNDRY=1 detect_run_identity)"
  [ "$FD" = "{}" ]                                   && ok "foundry(no principal): omitted → {}"       || bad "foundry omit: $FD"

  # 7. CCR — the local proxy base URL → OMIT even with a (dummy) token present. Upstream identity is
  #    deferred to SCRUM-1631; the stamp must degrade to empty, never the proxy's dummy fingerprint.
  C="$(ANTHROPIC_API_KEY='sk-dummy-ccr-proxy-key' ANTHROPIC_BASE_URL='http://127.0.0.1:3456' detect_run_identity)"
  [ "$C" = "{}" ]                                    && ok "ccr(local proxy): omitted → {} (deferred)" || bad "ccr omit: $C"
  case "$C" in *sk-dum*) bad "ccr: the proxy's dummy token leaked into a stamp" ;; *) ok "ccr: no dummy-token stamp" ;; esac

  # 8. No auth at all (no token, no cloud flag, no oauthAccount) → OMIT.
  N="$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY; HOME='/nonexistent-sb-xyz' detect_run_identity)"
  [ "$N" = "{}" ]                                    && ok "no-auth: omitted → {} (legacy-safe)"       || bad "no-auth omit: $N"

  # 9. Fingerprint shape (§4.3) — a token < 12 chars renders last-2 only (never the middle/whole value).
  SH="$(unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL; ANTHROPIC_API_KEY='abcd1234' detect_run_identity)"
  [ "$(field "$SH" id)" = "…34" ]                   && ok "short token: id=…last2"                    || bad "short token id: $(field "$SH" id)"

  # 10. The stamp is always a compact object or {} — never null / an array / a scalar.
  T="$(printf '%s' "$A" | jq -r 'type' 2>/dev/null || echo ERR)"
  [ "$T" = "object" ]                                && ok "stamp is a JSON object"                    || bad "stamp type: $T"
else
  skip "jq not installed — skipping the identity-matrix assertions (CI runs them)"
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
