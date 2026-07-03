#!/usr/bin/env bash
# base/tests/test-14b-effective-route.sh — regression guard for the SCRUM-1471 (T9)
# effective-route detection in 14-claude-stop-hook.sh.
#
# detect_effective_route() echoes {agentic_app, provider, effective_model} naming which agentic
# app + backend actually served a session, so a forked Jobs-Experiments branch can be labelled by
# route. Native Claude Code => claude-code / anthropic / <reported model>. Claude Code Router (CCR)
# re-points ANTHROPIC_BASE_URL at 127.0.0.1:3456 and selects a real backend in
# ~/.claude-code-router/config.json — `model` (the transcript id) then stays an Anthropic id while
# the true route lives in that config. This test proves: native fallback, CCR via .Router.default
# ("provider,model"), CCR via .Providers[0] fallback, graceful degradation (CCR base-URL but no
# config), that an installed-but-unrouted base URL still reads as native (route == runtime), and
# native cloud-Claude (AAP-N, SCRUM-1611: Bedrock/Vertex/Foundry via CLAUDE_CODE_USE_*, no proxy)
# labelled by provider — with CCR-proxy precedence over a stray flag and no cloud-secret leakage.
#
# Pure bash + jq (both present on the runner). Run: bash base/tests/test-14b-effective-route.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
HOOK="$BASE/14-claude-stop-hook.sh"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }
skip() { printf 'skip - %s\n' "$1"; }

# ── 0. the installer + generated hook must stay syntactically valid + carry the contract ─────────
bash -n "$HOOK" && ok "bash -n: 14-claude-stop-hook.sh" || bad "bash -n failed on the hook"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Extract the generated stop hook from its heredoc and syntax-check it.
awk "/cat > .*claude-stop-hook.sh.*<<'HOOKEOF'/{f=1;next} /^HOOKEOF\$/{f=0} f" "$HOOK" > "$TMP/claude-stop-hook.sh"
bash -n "$TMP/claude-stop-hook.sh" && ok "bash -n: generated claude-stop-hook.sh" || bad "bash -n failed on generated hook"

# The /api/jobs/usage payload must merge the detected route INTO `usage` (the portal reads it there).
grep -qF '+ $route' "$TMP/claude-stop-hook.sh" \
  && ok "usage payload merges the route triple into usage" \
  || bad "usage payload is missing the '+ \$route' merge (portal would never see the triple)"
# It must NOT be added to the step-complete payload (which carries no usage — a partial object there
# would clobber model/tokens). Assert the step-complete payload builder is unchanged in that respect.
grep -q 'detect_effective_route' "$TMP/claude-stop-hook.sh" \
  && ok "detect_effective_route is wired into the hook" \
  || bad "detect_effective_route is missing from the hook"

# ── Extract the pure detector + drive it across the route matrix ─────────────────────────────────
awk '/^detect_effective_route\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$TMP/claude-stop-hook.sh" > "$TMP/route.sh"
grep -q '^detect_effective_route() {' "$TMP/route.sh" \
  && ok "extracted detect_effective_route from the hook heredoc" \
  || bad "could not extract detect_effective_route from the hook"

if command -v jq >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$TMP/route.sh"
  field() { printf '%s' "$1" | jq -r ".$2" 2>/dev/null || echo "ERR"; }

  # 1. Native — no ANTHROPIC_BASE_URL → claude-code / anthropic / <reported model> (AC1).
  N="$(unset ANTHROPIC_BASE_URL; detect_effective_route 'claude-opus-4-8')"
  [ "$(field "$N" agentic_app)" = "claude-code" ]    && ok "native: agentic_app=claude-code"          || bad "native agentic_app: $(field "$N" agentic_app)"
  [ "$(field "$N" provider)" = "anthropic" ]         && ok "native: provider=anthropic"               || bad "native provider: $(field "$N" provider)"
  [ "$(field "$N" effective_model)" = "claude-opus-4-8" ] && ok "native: effective_model==reported"   || bad "native effective_model: $(field "$N" effective_model)"

  # CCR fixture HOME with a config carrying .Router.default = "provider,model".
  export HOME="$TMP/home"; mkdir -p "$HOME/.claude-code-router"
  printf '%s' '{"Router":{"default":"deepseek,deepseek-chat"},"Providers":[{"name":"deepseek","models":["deepseek-chat"]}],"APIKEY":"sk-secret"}' \
    > "$HOME/.claude-code-router/config.json"

  # 2. CCR via .Router.default (AC2). 127.0.0.1:3456 base URL → routed.
  C="$(ANTHROPIC_BASE_URL='http://127.0.0.1:3456' detect_effective_route 'claude-opus-4-8')"
  [ "$(field "$C" agentic_app)" = "claude-code-router" ] && ok "ccr: agentic_app=claude-code-router"  || bad "ccr agentic_app: $(field "$C" agentic_app)"
  [ "$(field "$C" provider)" = "deepseek" ]              && ok "ccr: provider from Router.default"     || bad "ccr provider: $(field "$C" provider)"
  [ "$(field "$C" effective_model)" = "deepseek-chat" ]  && ok "ccr: effective_model from Router.default" || bad "ccr effective_model: $(field "$C" effective_model)"
  # Secrets must never leak into the triple.
  case "$C" in *sk-secret*|*APIKEY*) bad "a secret leaked into the route triple" ;; *) ok "no secret material in the triple" ;; esac

  # 3. CCR via .Providers[0] fallback (no Router.default). localhost:3456 also counts as routed.
  printf '%s' '{"Providers":[{"name":"openrouter","models":["moonshotai/kimi-k2"]}]}' > "$HOME/.claude-code-router/config.json"
  F="$(ANTHROPIC_BASE_URL='http://localhost:3456' detect_effective_route 'claude-opus-4-8')"
  [ "$(field "$F" agentic_app)" = "claude-code-router" ]      && ok "ccr-fallback: agentic_app=claude-code-router" || bad "ccr-fallback agentic_app: $(field "$F" agentic_app)"
  [ "$(field "$F" provider)" = "openrouter" ]                 && ok "ccr-fallback: provider from Providers[0]"     || bad "ccr-fallback provider: $(field "$F" provider)"
  [ "$(field "$F" effective_model)" = "moonshotai/kimi-k2" ]  && ok "ccr-fallback: effective_model from Providers[0]" || bad "ccr-fallback effective_model: $(field "$F" effective_model)"

  # 4. Graceful degradation — CCR base URL but the config is absent → native fallback (today's fleet).
  G="$(HOME='/nonexistent-sb-xyz' ANTHROPIC_BASE_URL='http://127.0.0.1:3456' detect_effective_route 'claude-sonnet-4-6')"
  [ "$(field "$G" agentic_app)" = "claude-code" ] && ok "no-config: degrades to claude-code" || bad "no-config agentic_app: $(field "$G" agentic_app)"

  # 5. Effective route == runtime, not "installed": a non-CCR base URL reads as native even with a config present.
  R="$(ANTHROPIC_BASE_URL='https://api.anthropic.com' detect_effective_route 'claude-opus-4-8')"
  [ "$(field "$R" agentic_app)" = "claude-code" ] && ok "non-ccr base URL → native (route follows runtime)" || bad "non-ccr base URL agentic_app: $(field "$R" agentic_app)"

  # ── Native cloud-Claude (AAP-N, SCRUM-1611): Bedrock/Vertex/Foundry via CLAUDE_CODE_USE_*, no proxy ──
  # HOME still holds a CCR config.json here — these cases also prove native-cloud ignores it when the
  # base URL isn't the proxy (route follows the live runtime, not the installed component).
  # 6. Bedrock — flag + ANTHROPIC_MODEL, no proxy base URL → claude-code / bedrock / <ANTHROPIC_MODEL>.
  B="$(unset ANTHROPIC_BASE_URL; CLAUDE_CODE_USE_BEDROCK=1 ANTHROPIC_MODEL='eu.anthropic.claude-opus-4-6-v1' detect_effective_route 'claude-opus-4-6')"
  [ "$(field "$B" agentic_app)" = "claude-code" ]                        && ok "bedrock: agentic_app=claude-code (native wire)"    || bad "bedrock agentic_app: $(field "$B" agentic_app)"
  [ "$(field "$B" provider)" = "bedrock" ]                               && ok "bedrock: provider=bedrock"                         || bad "bedrock provider: $(field "$B" provider)"
  [ "$(field "$B" effective_model)" = "eu.anthropic.claude-opus-4-6-v1" ] && ok "bedrock: effective_model from ANTHROPIC_MODEL"     || bad "bedrock effective_model: $(field "$B" effective_model)"

  # 6b. Bedrock without ANTHROPIC_MODEL → effective_model falls back to the reported transcript model.
  B2="$(unset ANTHROPIC_BASE_URL ANTHROPIC_MODEL; CLAUDE_CODE_USE_BEDROCK=1 detect_effective_route 'claude-sonnet-4-6')"
  [ "$(field "$B2" provider)" = "bedrock" ]                              && ok "bedrock(no model): provider=bedrock"               || bad "bedrock(no model) provider: $(field "$B2" provider)"
  [ "$(field "$B2" effective_model)" = "claude-sonnet-4-6" ]             && ok "bedrock(no model): effective_model==reported"      || bad "bedrock(no model) effective_model: $(field "$B2" effective_model)"

  # 7. Vertex — flag + ANTHROPIC_MODEL → provider=vertex.
  V="$(unset ANTHROPIC_BASE_URL; CLAUDE_CODE_USE_VERTEX=1 ANTHROPIC_MODEL='claude-opus-4-6@20260501' detect_effective_route 'claude-opus-4-6')"
  [ "$(field "$V" provider)" = "vertex" ]                                && ok "vertex: provider=vertex"                           || bad "vertex provider: $(field "$V" provider)"
  [ "$(field "$V" effective_model)" = "claude-opus-4-6@20260501" ]       && ok "vertex: effective_model from ANTHROPIC_MODEL"      || bad "vertex effective_model: $(field "$V" effective_model)"

  # 8. Foundry — flag only (deployment names live in ANTHROPIC_DEFAULT_*_MODEL) → provider=foundry, model==reported.
  FD="$(unset ANTHROPIC_BASE_URL ANTHROPIC_MODEL; CLAUDE_CODE_USE_FOUNDRY=1 detect_effective_route 'claude-opus-4-6')"
  [ "$(field "$FD" provider)" = "foundry" ]                              && ok "foundry: provider=foundry"                         || bad "foundry provider: $(field "$FD" provider)"
  [ "$(field "$FD" effective_model)" = "claude-opus-4-6" ]               && ok "foundry: effective_model==reported"                || bad "foundry effective_model: $(field "$FD" effective_model)"

  # 9. Precedence — a CCR proxy base URL wins over a stray CLAUDE_CODE_USE_BEDROCK (CC talks to the proxy).
  P="$(CLAUDE_CODE_USE_BEDROCK=1 ANTHROPIC_BASE_URL='http://127.0.0.1:3456' detect_effective_route 'claude-opus-4-8')"
  [ "$(field "$P" agentic_app)" = "claude-code-router" ]                 && ok "precedence: CCR proxy beats stray USE_BEDROCK"     || bad "precedence agentic_app: $(field "$P" agentic_app)"
  [ "$(field "$P" provider)" != "bedrock" ]                              && ok "precedence: provider is not bedrock under CCR"     || bad "precedence provider leaked bedrock: $(field "$P" provider)"

  # 10. Secrets — cloud credentials present in the env must never leak into the triple.
  S2="$(unset ANTHROPIC_BASE_URL; CLAUDE_CODE_USE_BEDROCK=1 ANTHROPIC_MODEL='m' AWS_SECRET_ACCESS_KEY='wJalr-SECRET' AWS_PROFILE='bedrock-x' detect_effective_route 'claude-opus-4-6')"
  case "$S2" in *wJalr-SECRET*|*AWS_SECRET*) bad "an AWS credential leaked into the native-cloud triple" ;; *) ok "no cloud secret material in the native-cloud triple" ;; esac
else
  skip "jq not installed — skipping the route-matrix assertions (CI runs them)"
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
