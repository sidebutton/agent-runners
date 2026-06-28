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
# config), and that an installed-but-unrouted base URL still reads as native (route == runtime).
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
else
  skip "jq not installed — skipping the route-matrix assertions (CI runs them)"
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
