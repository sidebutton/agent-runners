#!/usr/bin/env bash
# base/tests/test-14c-run-identity.sh — regression guard for the AUTH-4 (SCRUM-1629,
# PROVIDER-AUTH-VISIBILITY.md §7) per-run auth-identity stamp in 14-claude-stop-hook.sh.
#
# detect_run_identity() echoes a compact NON-SECRET {method, id, base_host?} naming the auth identity
# that actually served a run — the subscription / key / cloud principal that spent the quota — so the
# portal can attribute burn (jobs.auth_identity) and roll up usage-by-identity. It parallels
# detect_effective_route (test-14b) and rides the SAME /api/jobs/usage POST, INSIDE `usage`. This test
# proves: the subscription / api_key / gateway / bedrock / vertex identities; the CCR upstream stamp
# (SCRUM-1631 — literal + `$VAR` configs, never the proxy's dummy token, never an unresolved
# placeholder); foundry / unrouted-CCR / no-auth omit (empty stamp, never a wrong one); the §4.3
# fingerprint shape (first-6 + … + last-4, short → …last-2)
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

# ── Extract the pure detector (+ its helpers) and drive it across the identity matrix ─────────────
awk '/^fp_token\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$TMP/claude-stop-hook.sh"  > "$TMP/ident.sh"
awk '/^url_host\(\) \{/{p=1} p{print} p&&/^\}$/{exit}'  "$TMP/claude-stop-hook.sh" >> "$TMP/ident.sh"
awk '/^ccr_deref\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$TMP/claude-stop-hook.sh" >> "$TMP/ident.sh"
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

  # ── 0b. url_host PARITY with the reporter's _base_host() ────────────────────────────────────────
  # url_host's contract is not "extract something host-shaped", it is "return exactly what the
  # reporter's Python _base_host() returns" — a run's stamp and the agent's ccr block are joined on
  # base_host, so any divergence silently splits one identity into two. The two implementations are
  # in different languages in different files, so pin them against each other directly rather than
  # against hand-copied expectations that can rot with either side. Cases chosen for the shapes bash
  # string surgery gets wrong where urlparse does not: userinfo (a SECRET must not become a host),
  # bracketed IPv6 (a first-colon split yields `[`, which also slips past the loopback filter — the
  # one guard that stops the local CCR proxy being stamped as the upstream), quotes, and ports.
  RPT="$BASE/assets/report-health-snapshot.sh"
  if command -v python3 >/dev/null 2>&1 && [ -f "$RPT" ]; then
    { echo 'import urllib.parse'
      sed -n '/^_LOCAL_HOSTS = /,/^def _parse_env_file/p' "$RPT" | sed '$d'
      cat <<'PYDRV'
import sys
print(_base_host(sys.argv[1]) or "")
PYDRV
    } > "$TMP/base_host.py"
    grep -q '^def _base_host' "$TMP/base_host.py" \
      && ok "extracted _base_host() from the reporter for a parity cross-check" \
      || bad "could not extract _base_host() from $RPT"
    uh_div=0
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      got="$(url_host "$u")"
      want="$(python3 "$TMP/base_host.py" "$u")"
      [ "$got" = "$want" ] || { bad "url_host parity: '$u' → bash '$got' vs reporter '$want'"; uh_div=$((uh_div+1)); }
    done <<'URLS'
https://api.moonshot.cn/anthropic
https://openrouter.ai/api/v1
https://api.z.ai:8443/v1
https://API.Z.AI/v1
api.z.ai
"https://api.z.ai/v1"
http://[fd00::1]:8000/v1
http://[2001:db8::1]:8080/v1
https://tokSECRET123@api.z.ai/v1
https://user:PASSWORD123@gw.corp.example:8443/v1
https://a@b@api.z.ai/v1
http://127.0.0.1:3456
http://localhost:3456
http://[::1]:3456
URLS
    [ "$uh_div" -eq 0 ] && ok "url_host matches the reporter's _base_host() on every case (0 divergences)"
    # The two shapes that must never be emitted, spelled out: a credential is not a host, and a
    # loopback proxy is not an identity no matter how it is written.
    [ -z "$(url_host 'http://[::1]:3456')" ]            && ok "url_host: IPv6 loopback proxy rejected (not stamped as an endpoint)" || bad "url_host stamped the IPv6 loopback proxy: '$(url_host 'http://[::1]:3456')'"
    case "$(url_host 'https://tokSECRET123@api.z.ai/v1')" in
      *SECRET*|*secret*) bad "url_host leaked URL userinfo (a credential) into base_host" ;;
      api.z.ai)          ok "url_host: userinfo stripped — only the host is stamped" ;;
      *)                 bad "url_host userinfo case: '$(url_host 'https://tokSECRET123@api.z.ai/v1')'" ;;
    esac
    [ "$(url_host 'http://[fd00::1]:8000/v1')" = "fd00::1" ] && ok "url_host: bracketed IPv6 literal unwrapped" || bad "url_host IPv6: '$(url_host 'http://[fd00::1]:8000/v1')'"
  else
    skip "python3 or the reporter absent — skipping url_host/_base_host parity cross-check"
  fi

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

  # 7. CCR (SCRUM-1631) — the local proxy base URL. The env names only the proxy, so the identity comes
  #    from the UPSTREAM provider in ~/.claude-code-router/config.json: method=ccr, id = fingerprint of
  #    Providers[0].api_key, base_host = its endpoint. The proxy's own dummy token must NEVER be stamped.
  CH="$TMP/home-ccr"; mkdir -p "$CH/.claude-code-router"
  CCR_UPSTREAM_KEY='sk-or-v1-UPSTREAMsecretMIDDLE-7777efgh'
  cat > "$CH/.claude-code-router/config.json" <<CFGEOF
{"HOST":"127.0.0.1","PORT":3456,"APIKEY":"sbccr_localdummytoken",
 "Providers":[{"name":"openrouter-app","api_base_url":"https://openrouter.ai/api/v1",
               "api_key":"$CCR_UPSTREAM_KEY","models":["moonshotai/kimi-k2"]}],
 "Router":{"default":"openrouter-app,moonshotai/kimi-k2"}}
CFGEOF
  C="$(HOME="$CH" ANTHROPIC_API_KEY='sbccr_dummyproxytoken' ANTHROPIC_BASE_URL='http://127.0.0.1:3456' detect_run_identity)"
  [ "$(field "$C" method)" = "ccr" ]                 && ok "ccr: method=ccr"                           || bad "ccr method: $(field "$C" method)"
  [ "$(field "$C" id)" = "sk-or-…efgh" ]             && ok "ccr: id=fingerprint of the UPSTREAM key"   || bad "ccr id: $(field "$C" id)"
  [ "$(field "$C" base_host)" = "openrouter.ai" ]    && ok "ccr: base_host=upstream endpoint host"     || bad "ccr base_host: $(field "$C" base_host)"
  case "$C" in *sbccr_*) bad "ccr: the proxy's dummy token leaked into the stamp" ;; *) ok "ccr: no proxy dummy token in the stamp" ;; esac
  case "$C" in *UPSTREAMsecret*|*"$CCR_UPSTREAM_KEY"*) bad "ccr: the RAW upstream key leaked into the stamp" ;; *) ok "ccr: no raw upstream key in the stamp" ;; esac
  # 127.0.0.1 must never surface as the identity's endpoint (the proxy is not a gateway).
  case "$(field "$C" base_host)" in 127.0.0.1|localhost) bad "ccr: the loopback proxy host was stamped as base_host" ;; *) ok "ccr: loopback host never stamped" ;; esac

  # 7b. CCR on the install-time TEMPLATE config ($VAR placeholders, interpolated by CCR at runtime):
  #     resolved from env → a real stamp; the literal `$CCR_PROVIDER_*` must never become the identity.
  CT="$TMP/home-ccr-tmpl"; mkdir -p "$CT/.claude-code-router"
  cat > "$CT/.claude-code-router/config.json" <<'CFGEOF'
{"HOST":"127.0.0.1","PORT":3456,"APIKEY":"$ANTHROPIC_AUTH_TOKEN",
 "Providers":[{"name":"$CCR_PROVIDER_NAME","api_base_url":"$CCR_PROVIDER_API_BASE_URL",
               "api_key":"$CCR_PROVIDER_API_KEY","models":["$CCR_PROVIDER_MODEL"]}],
 "Router":{"default":"$CCR_PROVIDER_NAME,$CCR_PROVIDER_MODEL"}}
CFGEOF
  CV="$(HOME="$CT" ANTHROPIC_API_KEY='sbccr_dummyproxytoken' ANTHROPIC_BASE_URL='http://127.0.0.1:3456' \
        CCR_PROVIDER_API_KEY='sk-kimi-TEMPLATEresolved-4444wxyz' CCR_PROVIDER_API_BASE_URL='https://api.moonshot.cn/anthropic' \
        detect_run_identity)"
  [ "$(field "$CV" method)" = "ccr" ]                && ok "ccr(\$VAR + env): method=ccr"              || bad "ccr \$VAR method: $(field "$CV" method)"
  [ "$(field "$CV" id)" = "sk-kim…wxyz" ]            && ok "ccr(\$VAR + env): id=fp of the resolved key" || bad "ccr \$VAR id: $(field "$CV" id)"
  [ "$(field "$CV" base_host)" = "api.moonshot.cn" ] && ok "ccr(\$VAR + env): base_host resolved"      || bad "ccr \$VAR base_host: $(field "$CV" base_host)"

  # 7c. Same template with NOTHING in env → OMIT. A stamp of the literal `$CCR_PROVIDER_API_KEY` would
  #     fabricate an identity that every unrouted CCR box shares.
  CN="$(unset CCR_PROVIDER_API_KEY CCR_PROVIDER_API_BASE_URL; HOME="$CT" ANTHROPIC_API_KEY='sbccr_dummyproxytoken' \
        ANTHROPIC_BASE_URL='http://127.0.0.1:3456' detect_run_identity)"
  [ "$CN" = "{}" ]                                   && ok "ccr(unresolved \$VAR): omitted → {}"       || bad "ccr unresolved: $CN"
  case "$CN" in *CCR_PROVIDER*) bad "ccr: a \$VAR placeholder leaked into the stamp" ;; *) ok "ccr: no placeholder in the stamp" ;; esac

  # 7d. CCR proxy with NO readable config (component installed, no app row) → OMIT, never the dummy.
  CX="$(unset CCR_PROVIDER_API_KEY CCR_PROVIDER_API_BASE_URL; HOME="$TMP/home-none-xyz" \
        ANTHROPIC_API_KEY='sbccr_dummyproxytoken' ANTHROPIC_BASE_URL='http://127.0.0.1:3456' detect_run_identity)"
  [ "$CX" = "{}" ]                                   && ok "ccr(no config): omitted → {} (legacy-safe)" || bad "ccr no-config: $CX"
  case "$CX" in *sbccr_*) bad "ccr: the proxy's dummy token was stamped when the config was unreadable" ;; *) ok "ccr(no config): no dummy-token stamp" ;; esac

  # 7e. Legacy cloud-init contract: NO config on disk, upstream only in CCR_PROVIDER_* env → stamp it.
  CL="$(HOME="$TMP/home-none-xyz" ANTHROPIC_API_KEY='sbccr_dummyproxytoken' ANTHROPIC_BASE_URL='http://127.0.0.1:3456' \
        CCR_PROVIDER_API_KEY='sk-kimi-LEGACYenvkey-5555abcd' CCR_PROVIDER_API_BASE_URL='https://api.moonshot.cn/anthropic' \
        detect_run_identity)"
  [ "$(field "$CL" id)" = "sk-kim…abcd" ]            && ok "ccr(legacy env, no config): id=fp of the env key" || bad "ccr legacy id: $(field "$CL" id)"
  [ "$(field "$CL" base_host)" = "api.moonshot.cn" ] && ok "ccr(legacy env, no config): base_host from env"   || bad "ccr legacy base_host: $(field "$CL" base_host)"

  # 7f. A config that OMITS api_key (an app row with no stored secret) must NOT borrow a stray env key —
  #     CCR would not use it either, so a stamp built from it names an identity that served nothing.
  CK="$TMP/home-ccr-nokey"; mkdir -p "$CK/.claude-code-router"
  cat > "$CK/.claude-code-router/config.json" <<'CFGEOF'
{"HOST":"127.0.0.1","PORT":3456,"Providers":[{"name":"kimi-app","api_base_url":"https://api.moonshot.cn/anthropic","models":["kimi-k2"]}],
 "Router":{"default":"kimi-app,kimi-k2"}}
CFGEOF
  CKS="$(HOME="$CK" ANTHROPIC_API_KEY='sbccr_dummyproxytoken' ANTHROPIC_BASE_URL='http://127.0.0.1:3456' \
         CCR_PROVIDER_API_KEY='sk-kimi-STRAYenvkey-6666abcd' detect_run_identity)"
  [ "$CKS" = "{}" ]                                  && ok "ccr(config without api_key): omitted → {}"  || bad "ccr keyless config: $CKS"
  case "$CKS" in *STRAY*|*sk-kim*) bad "ccr: a stray env key was stamped over a keyless config" ;; *) ok "ccr: no stray env key borrowed" ;; esac

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
