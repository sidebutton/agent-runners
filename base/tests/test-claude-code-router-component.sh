#!/usr/bin/env bash
# base/tests/test-claude-code-router-component.sh — regression guard for SCRUM-1446 (T3).
#
# The `claude-code-router` (CCR) component must (AC1/AC5) be a schema-shaped catalog
# entry (runtime, requires claude-code) that resolves to base/components/claude-code-router/
# AND be wired into run.sh — a dedicated install include + the generalized post-services
# loop (the silent-failure trap: dir+JSON without the run.sh edit => never installs/starts);
# (AC2) ship a config.json with HOST/NON_INTERACTIVE_MODE + $ENV placeholders + a
# CCR_CONFIG_B64 override branch, an enabled-not-started ccr.service, and logrotate;
# (AC4/AC5) post-services starts + health-checks CCR, and components.sh force-enables
# claude-code when CCR is selected.
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-claude-code-router-component.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
CATALOG="$ROOT/components.json"
RUN="$ROOT/base/run.sh"
COMPONENTS_SH="$ROOT/base/components.sh"
DIR="$ROOT/base/components/claude-code-router"
INSTALL="$DIR/install.sh"
POST="$DIR/post-services.sh"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# ── AC1: catalog entry, schema-shaped ────────────────────────────────────────
jq -e . "$CATALOG" >/dev/null 2>&1 && ok "components.json is valid JSON" \
  || bad "components.json is not valid JSON"

ENTRY='.components[] | select(.slug=="claude-code-router")'
[ "$(jq -r "$ENTRY | .slug" "$CATALOG")" = "claude-code-router" ] \
  && ok "claude-code-router entry present" || bad "claude-code-router entry missing"
[ "$(jq -r "$ENTRY | .kind" "$CATALOG")" = "runtime" ] \
  && ok "kind = runtime" || bad "kind != runtime"
# requires claude-code (AC5 contract — the dependency the wizard + components.sh enforce)
jq -e "$ENTRY | .requires | index(\"claude-code\")" "$CATALOG" >/dev/null 2>&1 \
  && ok "requires includes claude-code" || bad "requires missing claude-code"
[ "$(jq -r "$ENTRY | .chip.label" "$CATALOG")" = "Router" ] \
  && ok "chip.label = Router" || bad "chip.label != Router"
[ "$(jq -r "$ENTRY | .chip.live" "$CATALOG")" = "false" ] \
  && ok "chip.live = false" || bad "chip.live != false"
[ -n "$(jq -r "$ENTRY | .title // empty" "$CATALOG")" ] \
  && ok "title present" || bad "title missing"
# slug satisfies the schema pattern ^[a-z0-9][a-z0-9-]*$
jq -r '.components[].slug' "$CATALOG" | grep -qE '^claude-code-router$' \
  && ok "slug matches schema pattern" || bad "slug fails schema pattern"

# ── AC1/AC4: run.sh wiring (else the component silently never installs/starts) ─
grep -qF 'components/claude-code-router/install.sh' "$RUN" \
  && ok "run.sh sources the CCR install include" \
  || bad "run.sh MISSING the CCR install include (component would never install)"
grep -Eq 'for _c in .*\bclaude-code-router\b' "$RUN" \
  && ok "run.sh pre/post-services loop names claude-code-router" \
  || bad "run.sh pre/post-services loop MISSING claude-code-router (never starts)"

# ── component files exist + parse ────────────────────────────────────────────
[ -f "$INSTALL" ] && ok "install.sh present" || bad "install.sh missing"
[ -f "$POST" ]    && ok "post-services.sh present" || bad "post-services.sh missing"
bash -n "$INSTALL" 2>/dev/null && ok "install.sh: bash -n clean" || bad "install.sh: bash -n failed"
bash -n "$POST"    2>/dev/null && ok "post-services.sh: bash -n clean" || bad "post-services.sh: bash -n failed"

# ── AC1: install.sh installs the PINNED CCR package ──────────────────────────
grep -q '@musistudio/claude-code-router@' "$INSTALL" \
  && ok "install.sh installs @musistudio/claude-code-router (pinned)" \
  || bad "install.sh missing pinned @musistudio/claude-code-router"
grep -Eq 'CCR_VERSION="[0-9]+\.[0-9]+\.[0-9]+"' "$INSTALL" \
  && ok "install.sh pins an exact CCR version" || bad "install.sh CCR version not pinned exact"

# ── AC1: ccr.service written (User=agent, EnvironmentFile, ccr start), enabled-not-started
grep -q '/etc/systemd/system/ccr.service' "$INSTALL" && ok "install.sh writes ccr.service" || bad "install.sh missing ccr.service"
grep -q 'User=agent' "$INSTALL" && ok "ccr.service runs as User=agent" || bad "ccr.service not User=agent"
grep -q 'EnvironmentFile=/home/agent/.agent-env' "$INSTALL" \
  && ok "ccr.service reads ~/.agent-env (EnvironmentFile)" || bad "ccr.service missing EnvironmentFile=~/.agent-env"
grep -Eq 'ExecStart=.*ccr start' "$INSTALL" && ok "ccr.service ExecStart = ccr start" || bad "ccr.service ExecStart != ccr start"
grep -q 'Restart=always' "$INSTALL" && ok "ccr.service Restart=always" || bad "ccr.service missing Restart=always"
grep -q 'systemctl enable ccr.service' "$INSTALL" \
  && ok "install.sh enables ccr.service" || bad "install.sh does not enable ccr.service"
# enable-not-start: the first start is deferred to post-services (no start/--now at install)
grep -Eq 'systemctl[[:space:]]+(start|enable[[:space:]]+--now)[[:space:]]+ccr' "$INSTALL" \
  && bad "install.sh STARTS ccr at install (must defer the first start to post-services)" \
  || ok "install.sh does not start ccr (first start deferred to post-services)"

# ── AC2: config.json shape — HOST/NON_INTERACTIVE_MODE + $ENV placeholders + B64 branch
grep -q '"HOST": "127.0.0.1"' "$INSTALL" && ok "config HOST = 127.0.0.1" || bad "config missing HOST 127.0.0.1"
grep -q '"NON_INTERACTIVE_MODE": true' "$INSTALL" && ok "config NON_INTERACTIVE_MODE = true" || bad "config missing NON_INTERACTIVE_MODE"
grep -q '\$ANTHROPIC_AUTH_TOKEN' "$INSTALL" && ok "config APIKEY uses \$ANTHROPIC_AUTH_TOKEN placeholder" || bad "config missing \$ANTHROPIC_AUTH_TOKEN"
grep -q '\$CCR_PROVIDER_NAME' "$INSTALL" && ok "config Providers use \$CCR_PROVIDER_* placeholders" || bad "config missing \$CCR_PROVIDER_NAME"
# the placeholders must be LITERAL — written via a single-quoted heredoc (else bash
# expands them to empty at install and the config is dead).
grep -q "<<'EOF'" "$INSTALL" && ok "config heredoc is single-quoted (placeholders stay literal)" || bad "config heredoc NOT single-quoted (\$VARs would expand empty)"
# schema-compat with base/14 detect_effective_route (T9): Router.default "provider,model"
grep -q '"Router": { "default": "\$CCR_PROVIDER_NAME,\$CCR_PROVIDER_MODEL" }' "$INSTALL" \
  && ok "Router.default keeps the \"provider,model\" shape (T9 route detection)" \
  || bad "Router.default shape changed (would break base/14 detect_effective_route)"
grep -q 'CCR_CONFIG_B64' "$INSTALL" && ok "install.sh honors a CCR_CONFIG_B64 whole-config override" || bad "install.sh missing CCR_CONFIG_B64 branch"

# ── AC1: logrotate written for the CCR logs ──────────────────────────────────
grep -q '/etc/logrotate.d/claude-code-router' "$INSTALL" && ok "install.sh writes logrotate config" || bad "install.sh missing logrotate config"

# ── AC4: post-services starts + health-checks CCR, WARN-not-die ──────────────
grep -q 'systemctl restart ccr.service' "$POST" \
  && ok "post-services (re)starts ccr.service (its first start)" || bad "post-services does not start ccr.service"
grep -q '127.0.0.1:3456' "$POST" && ok "post-services health-checks 127.0.0.1:3456" || bad "post-services missing 127.0.0.1:3456 probe"
grep -q 'WARN' "$POST" && ok "post-services WARNs (does not die) on a failed probe" || bad "post-services has no WARN path (would die under set -e)"

# ── AC1/AC4 runtime guard: post-services.sh is SOURCED into run.sh's `set -euo
#    pipefail` shell. The CCR_CONFIG_B64 lookup is a `grep|...|sed` pipeline whose
#    exit status, under pipefail, is grep's — which is 1 when the (optional) key is
#    absent (the common case). An unguarded `var=$(that pipeline)` therefore aborts
#    the whole provision before ccr.service is ever started. bash -n cannot see this;
#    actually source the script (externals stubbed) and assert it completes.
_guard_home="$(mktemp -d)"
printf 'SOMEKEY="x"\n' > "$_guard_home/.agent-env"   # deliberately no CCR_CONFIG_B64
# NB: the subshell MUST be a standalone statement whose exit status we capture in
# $? — NOT an `if (...)` / `(...) ||` test. bash ignores `set -e` inside a subshell
# that is itself the condition of if/while/&&/||, which would make this guard
# false-pass on the very abort it checks for.
(
  set -euo pipefail
  step() { :; }; log() { :; }; systemctl() { :; }; curl() { :; }; sleep() { :; }
  AGENT_HOME="$_guard_home"; AGENT_USER="$(id -un)"
  . "$POST"
) >/dev/null 2>&1
_guard_rc=$?
rm -rf "$_guard_home"
[ "$_guard_rc" -eq 0 ] \
  && ok "post-services.sh survives set -euo pipefail when CCR_CONFIG_B64 is absent (no grep/pipefail abort)" \
  || bad "post-services.sh ABORTS under set -euo pipefail when CCR_CONFIG_B64 absent (unguarded grep|...|sed assignment)"

# ── AC5: components.sh force-enables claude-code when CCR is selected ─────────
grep -q 'claude-code-router requires claude-code' "$COMPONENTS_SH" \
  && ok "components.sh enforces claude-code-router requires claude-code" \
  || bad "components.sh MISSING the claude-code-router requires-claude-code enforcement"

if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "All checks passed."
