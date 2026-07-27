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
SYNC="$DIR/sb-ccr-sync"
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
# SCRUM-1613: the EnvironmentFile is the DERIVED sidecar, never the global env — the whole point of
# the isolation. `-` so an agent with no CCR app row yet still boots the proxy.
grep -q 'EnvironmentFile=-/home/agent/.claude-code-router/ccr.env' "$INSTALL" \
  && ok "ccr.service reads the derived sidecar (EnvironmentFile=-…/ccr.env)" \
  || bad "ccr.service does not read ~/.claude-code-router/ccr.env"
grep -q 'EnvironmentFile=/home/agent/.agent-env' "$INSTALL" \
  && bad "ccr.service still reads the GLOBAL ~/.agent-env (SCRUM-1613 removed that coupling)" \
  || ok "ccr.service does NOT read the global ~/.agent-env"
grep -Eq 'ExecStart=.*ccr start' "$INSTALL" && ok "ccr.service ExecStart = ccr start" || bad "ccr.service ExecStart != ccr start"
grep -q 'Restart=always' "$INSTALL" && ok "ccr.service Restart=always" || bad "ccr.service missing Restart=always"
grep -q 'systemctl enable ccr.service' "$INSTALL" \
  && ok "install.sh enables ccr.service" || bad "install.sh does not enable ccr.service"
# enable-not-start: the first start of the PROXY is deferred to post-services (no start/--now at
# install). Anchored on the ccr unit itself — `ccr-env-sync.path` is deliberately started here
# (starting a .path unit only attaches its inotify watch; it runs nothing).
grep -Eq 'systemctl[[:space:]]+(start|enable[[:space:]]+--now)[[:space:]]+ccr(\.service)?([[:space:]]|$)' "$INSTALL" \
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

# ── SCRUM-1613: the app-row → daemon bridge (helper, units, post-services wiring) ─
[ -f "$SYNC" ] && ok "sb-ccr-sync present" || bad "sb-ccr-sync missing"
[ -x "$SYNC" ] && ok "sb-ccr-sync is executable in-repo" || bad "sb-ccr-sync not executable (install -m 0755 needs a runnable source)"
bash -n "$SYNC" 2>/dev/null && ok "sb-ccr-sync: bash -n clean" || bad "sb-ccr-sync: bash -n failed"
grep -q 'install -m 0755 "$CCR_SYNC_SRC" /usr/local/bin/sb-ccr-sync' "$INSTALL" \
  && ok "install.sh installs sb-ccr-sync" || bad "install.sh does not install sb-ccr-sync"
grep -q 'ccr-env-sync.path' "$INSTALL" && ok "install.sh writes ccr-env-sync.path" || bad "install.sh missing ccr-env-sync.path"
grep -q 'PathModified=/home/agent/.agent-env.d' "$INSTALL" \
  && ok "the watcher follows ~/.agent-env.d (live applies reach the daemon)" \
  || bad "ccr-env-sync.path does not watch ~/.agent-env.d"
# Level-triggered specs re-fire when the triggered unit stops, and this sync never empties the dir it
# watches — boot coverage comes from enabling the oneshot, not from a condition that stays true.
grep -Eq '^(PathExists|DirectoryNotEmpty)=' "$INSTALL" \
  && bad "ccr-env-sync.path uses a level-triggered spec (re-trigger loop on a dir that is never emptied)" \
  || ok "ccr-env-sync.path is edge-triggered only"
grep -q 'systemctl enable --now ccr-env-sync.path' "$INSTALL" \
  && ok "install.sh enables the watcher" || bad "install.sh does not enable ccr-env-sync.path"
grep -q 'sb-ccr-sync --no-restart' "$POST" \
  && ok "post-services derives via sb-ccr-sync --no-restart (it owns the first start)" \
  || bad "post-services does not call sb-ccr-sync --no-restart"
# A write landing WHILE the oneshot runs is not guaranteed to raise another trigger (systemd drops the
# watch for the duration of the triggered unit and does not re-fire an edge spec when it re-arms), so
# the unit re-derives once before exiting — otherwise a second apply inside that window is lost until
# some later write pokes the dir.
grep -q 'ExecStartPost=-/usr/local/bin/sb-ccr-sync' "$INSTALL" \
  && ok "ccr-env-sync.service re-derives after its run (a write inside the window is not lost)" \
  || bad "ccr-env-sync.service has no post-run re-derive (an apply during the sync would be dropped)"

# ── F5 collector: the reported unit state must be a SINGLE token the portal can render ──────────
# `systemctl is-active` prints the state AND exits non-zero for everything but `active`, so the
# `|| echo "unknown"` idiom would ship "inactive\nunknown" straight into the Validate line.
SNAP="$ROOT/base/assets/report-health-snapshot.sh"
grep -q 'CCR_STATUS=$(systemctl is-active ccr 2>/dev/null || echo' "$SNAP" \
  && bad "report-health-snapshot appends to is-active output (ships a two-line CCR_STATUS)" \
  || ok "report-health-snapshot does not append to is-active output"
grep -q 'export CCR_STATUS="${CCR_STATUS:-unknown}"' "$SNAP" \
  && ok "CCR_STATUS defaults to unknown only when nothing was printed" \
  || bad "CCR_STATUS has no empty-only default"
grep -q '"ccr_proxy"' "$SNAP" && ok "snapshot reports processes.ccr_proxy (F5)" || bad "snapshot does not report ccr_proxy"
# Drive the collector's own idiom against a unit that does not exist — the state must stay one token.
_st=$(systemctl is-active definitely-not-a-real-unit.service 2>/dev/null); _st="${_st:-unknown}"
[ "$(printf '%s' "$_st" | wc -l)" = "0" ] \
  && ok "is-active capture yields a single-line state ($_st)" \
  || bad "is-active capture yielded a multi-line state"

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

# ── SCRUM-1613 behaviour: actually RUN sb-ccr-sync against a fake agent home ──
# The static greps above cannot see the two properties this whole design rests on: that the derived
# sidecar is parseable as a systemd EnvironmentFile (the BUG-2 format trap), and that a restart happens
# only when the daemon's inputs really changed (a restart per apply would kill in-flight requests).
# systemctl is stubbed onto PATH so every call it makes is observable.
_sbx="$(mktemp -d)"
_bin="$_sbx/bin"; mkdir -p "$_bin"
cat > "$_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
STUB
chmod +x "$_bin/systemctl"

_home="$_sbx/home"; mkdir -p "$_home/.agent-env.d" "$_home/.claude-code-router"
SIDECAR="$_home/.claude-code-router/ccr.env"
CONFIG="$_home/.claude-code-router/config.json"
export SYSTEMCTL_LOG="$_sbx/systemctl.log"

# A slug file exactly as the two writers produce it — `export KEY="VALUE"` (base/19-secrets.sh:69 and
# the sidebutton server's serializeAppEnv).
_write_slug() {  # _write_slug <slug> <b64>
  {
    printf 'export ANTHROPIC_AUTH_TOKEN="sbccr_deadbeef"\n'
    printf 'export ANTHROPIC_BASE_URL="http://127.0.0.1:3456"\n'
    printf 'export CCR_CONFIG_B64="%s"\n' "$2"
  } > "$_home/.agent-env.d/$1"
}
_b64_of() { printf '%s' "$1" | base64 -w0; }
_run_sync() {
  : > "$SYSTEMCTL_LOG"
  PATH="$_bin:$PATH" SB_AGENT_HOME="$_home" SB_AGENT_USER="$(id -un)" SB_CCR_RUN_DIR="$_sbx/run" \
    bash "$SYNC" "$@" > "$_sbx/out.log" 2>&1
}

_CFG_A='{"HOST":"127.0.0.1","PORT":3456,"APIKEY":"$ANTHROPIC_AUTH_TOKEN","Providers":[{"name":"team-gpt","api_base_url":"https://api.openai.com/v1/chat/completions","api_key":"sk-up","models":["gpt-5"]}],"Router":{"default":"team-gpt,gpt-5"}}'
_CFG_B="${_CFG_A/gpt-5/gpt-5-codex}"

# 1. derive from the app row: bare sidecar + decoded config + one restart
_write_slug team-gpt "$(_b64_of "$_CFG_A")"
_run_sync
[ -f "$SIDECAR" ] && ok "sync: derives the sidecar from ~/.agent-env.d/<slug>" || bad "sync: no sidecar derived"
grep -q '^export ' "$SIDECAR" 2>/dev/null \
  && bad "sync: sidecar still carries 'export' (systemd would ignore every line)" \
  || ok "sync: sidecar is bare KEY=VALUE (systemd-parseable)"
# The exact extractor post-services/19-secrets use — proves the format bridge closed BUG-2.
[ "$(grep -E '^CCR_CONFIG_B64=' "$SIDECAR" | tail -n1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')" = "$(_b64_of "$_CFG_A")" ] \
  && ok "sync: the bare-format extractor finds CCR_CONFIG_B64 in the sidecar" \
  || bad "sync: CCR_CONFIG_B64 not extractable from the sidecar"
grep -qvE '^[A-Za-z_][A-Za-z0-9_]*=' "$SIDECAR" \
  && bad "sync: sidecar has a line systemd cannot parse" \
  || ok "sync: every sidecar line is a bare assignment"
[ "$(cat "$CONFIG")" = "$_CFG_A" ] && ok "sync: config.json decoded from CCR_CONFIG_B64" || bad "sync: config.json not decoded"
grep -q 'restart ccr.service' "$SYSTEMCTL_LOG" && ok "sync: restarts CCR on a real change" || bad "sync: did not restart CCR after deriving"

# 2. the sha-gate: the reconciler rewrites slug files on EVERY apply — an unchanged one must not bounce
#    the daemon under live traffic.
_write_slug team-gpt "$(_b64_of "$_CFG_A")"
_run_sync
[ -s "$SYSTEMCTL_LOG" ] \
  && bad "sync: restarted CCR on an unchanged rewrite (would kill in-flight requests every apply)" \
  || ok "sync: unchanged rewrite ⇒ no restart (sha-gated)"

# 3. a real upstream change does reach the daemon (F4)
_write_slug team-gpt "$(_b64_of "$_CFG_B")"
_run_sync
[ "$(cat "$CONFIG")" = "$_CFG_B" ] && ok "sync: a changed payload rewrites config.json" || bad "sync: changed payload not applied"
grep -q 'restart ccr.service' "$SYSTEMCTL_LOG" && ok "sync: restarts CCR when the payload changed" || bad "sync: no restart on a changed payload"

# 4. --no-restart (the provision path, where post-services owns the first start)
_write_slug team-gpt "$(_b64_of "$_CFG_A")"
_run_sync --no-restart
[ "$(cat "$CONFIG")" = "$_CFG_A" ] && ok "sync --no-restart: still derives" || bad "sync --no-restart: did not derive"
grep -q 'restart' "$SYSTEMCTL_LOG" \
  && bad "sync --no-restart: restarted anyway (would double-start at provision)" \
  || ok "sync --no-restart: leaves the (re)start to the caller"

# 5. two CCR apps: one proxy can serve one — the pick must be deterministic and LOUD
_write_slug a-first "$(_b64_of "${_CFG_A/team-gpt/a-first}")"
_run_sync
grep -q 'a-first' "$CONFIG" && ok "sync: multi-app pick is deterministic (sorted first)" || bad "sync: multi-app pick is not the sorted-first file"
grep -q 'WARN: 2 CCR apps' "$_sbx/out.log" && ok "sync: WARNs when a second CCR app is in scope" || bad "sync: silent last-wins on two CCR apps"
rm -f "$_home/.agent-env.d/a-first"

# 6. a corrupt payload must never leave the daemon with an empty config
_write_slug team-gpt 'not-valid-base64!!'
_run_sync
[ "$(cat "$CONFIG")" = "${_CFG_A/team-gpt/a-first}" ] \
  && ok "sync: keeps the last good config.json when the payload does not decode" \
  || bad "sync: a bad payload damaged config.json"
grep -q 'WARN' "$_sbx/out.log" && ok "sync: WARNs on an undecodable payload" || bad "sync: silent on an undecodable payload"

# 7. reconcile to zero: the app was deleted or de-scoped (AC2)
rm -f "$_home/.agent-env.d/team-gpt"
_run_sync
[ -f "$SIDECAR" ] && bad "sync: sidecar survived the app's removal" || ok "sync: removes the sidecar when the app is gone"
grep -q 'stop ccr.service' "$SYSTEMCTL_LOG" && ok "sync: stops CCR when nothing routes (no crash-loop)" || bad "sync: left CCR running with no config"

# 8. never-managed: a component-only VM (or one with only native apps) must be left alone
printf 'export ANTHROPIC_API_KEY="sk-native"\n' > "$_home/.agent-env.d/cc-api"
_run_sync
[ -s "$SYSTEMCTL_LOG" ] \
  && bad "sync: touched systemd on an agent it never managed" \
  || ok "sync: no CCR app and no managed sidecar ⇒ no-op"
[ -f "$SIDECAR" ] && bad "sync: derived a sidecar from a native (non-CCR) app file" || ok "sync: ignores non-CCR slug files"

rm -rf "$_sbx"
unset -f _write_slug _b64_of _run_sync

# ── AC5: components.sh force-enables claude-code when CCR is selected ─────────
grep -q 'claude-code-router requires claude-code' "$COMPONENTS_SH" \
  && ok "components.sh enforces claude-code-router requires claude-code" \
  || bad "components.sh MISSING the claude-code-router requires-claude-code enforcement"

if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "All checks passed."
