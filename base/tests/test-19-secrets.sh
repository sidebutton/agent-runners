#!/usr/bin/env bash
# base/tests/test-19-secrets.sh — regression guard for SCRUM-1196.
#
# The portal secrets endpoint (the-assistant /api/agents/secrets) returns
#   { "agent_env": { KEY: VALUE, ... }, "rdp_password": "..." }
# base/19-secrets.sh must read the env vars from .agent_env (NOT .env); reading
# .env makes ENV_KEYS empty and silently writes zero account env vars to
# ~/.agent-env at provision (only rdp_password lands).
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-19-secrets.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP="$SCRIPT_DIR/../19-secrets.sh"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# Fixture mirrors the real wire shape (keys only; values are dummies).
FIXTURE="$(mktemp)"
trap 'rm -f "$FIXTURE"' EXIT
cat >"$FIXTURE" <<'JSON'
{
  "agent_env": {
    "GH_TOKEN": "ghp_dummy",
    "ANTHROPIC_API_KEY": "sk-dummy",
    "SIDEBUTTON_DEFAULT_REGISTRY_TOKEN": "reg-dummy"
  },
  "agent_app_env": {
    "cc-api-fable": { "ANTHROPIC_API_KEY": "sk-ant-fable" },
    "cc-gateway": { "ANTHROPIC_BASE_URL": "https://gw.example/v1", "ANTHROPIC_AUTH_TOKEN": "gw-token" }
  },
  "rdp_password": "dummy-rdp"
}
JSON

# 1. The corrected filter extracts every agent_env key.
keys="$(jq -r '.agent_env | keys[]' "$FIXTURE" | sort | tr '\n' ' ')"
[ "$keys" = "ANTHROPIC_API_KEY GH_TOKEN SIDEBUTTON_DEFAULT_REGISTRY_TOKEN " ] \
  && ok ".agent_env keys parse" || bad ".agent_env keys parse (got: $keys)"

# 2. The per-key value lookup the step uses resolves.
[ "$(jq -r --arg k GH_TOKEN '.agent_env[$k]' "$FIXTURE")" = "ghp_dummy" ] \
  && ok '.agent_env[$k] resolves' || bad '.agent_env[$k] resolves'

# 3. The old buggy key (.env) is absent — this is the SCRUM-1196 failure mode.
[ -z "$(jq -r '.env // empty | keys[]?' "$FIXTURE")" ] \
  && ok ".env is absent (regression sentinel)" || bad ".env unexpectedly present"

# 4. rdp_password stays top-level and still resolves.
[ "$(jq -r '.rdp_password // empty' "$FIXTURE")" = "dummy-rdp" ] \
  && ok ".rdp_password resolves" || bad ".rdp_password resolves"

# 5. The step script reads .agent_env and no longer reads the old .env keys
#    filter — guards against a silent revert.
grep -q 'agent_env | keys\[\]' "$STEP" \
  && ok "19-secrets.sh reads .agent_env keys" || bad "19-secrets.sh missing .agent_env keys filter"
grep -q '\.env | keys\[\]' "$STEP" \
  && bad "19-secrets.sh still reads .env keys (SCRUM-1196 regression)" \
  || ok "19-secrets.sh no longer reads .env keys"

# ── AAP-C (SCRUM-1506): per-app env delivery → ~/.agent-env.d/<slug> ──────────────────────────────
# 6. The new .agent_app_env map parses: a slug list, and each slug's nested {KEY:VALUE} resolves.
app_slugs="$(jq -r '.agent_app_env // {} | keys[]' "$FIXTURE" | sort | tr '\n' ' ')"
[ "$app_slugs" = "cc-api-fable cc-gateway " ] \
  && ok ".agent_app_env slugs parse" || bad ".agent_app_env slugs parse (got: $app_slugs)"
[ "$(jq -r '.agent_app_env["cc-api-fable"].ANTHROPIC_API_KEY' "$FIXTURE")" = "sk-ant-fable" ] \
  && ok ".agent_app_env[slug][key] resolves" || bad ".agent_app_env[slug][key] resolves"

# 7. Faithful replay of the step's write-loop stages each per-app file with `export KEY="VALUE"` lines
#    and 0600 perms; sourcing it must EXPORT the key to a child (the ops YAML `source`s it before claude).
TMP_HOME="$(mktemp -d)"
trap 'rm -f "$FIXTURE"; rm -rf "$TMP_HOME"' EXIT
APP_ENV_DIR="$TMP_HOME/.agent-env.d"
mkdir -p "$APP_ENV_DIR"; chmod 700 "$APP_ENV_DIR"
for slug in $(jq -r '.agent_app_env // {} | keys[]' "$FIXTURE"); do
  APP_KEYS="$(jq -r --arg s "$slug" '.agent_app_env[$s] | keys[]' "$FIXTURE" 2>/dev/null || echo "")"
  [ -n "$APP_KEYS" ] || continue
  APP_FILE="$APP_ENV_DIR/$slug"
  ( umask 177; : > "$APP_FILE" )
  for key in $APP_KEYS; do
    val="$(jq -r --arg s "$slug" --arg k "$key" '.agent_app_env[$s][$k]' "$FIXTURE" 2>/dev/null || echo "")"
    echo "export ${key}=\"${val}\"" >> "$APP_FILE"
  done
  chmod 600 "$APP_FILE"
done
[ -f "$APP_ENV_DIR/cc-api-fable" ] \
  && ok "per-app file cc-api-fable staged" || bad "per-app file cc-api-fable missing"
[ "$(grep -c '^export ' "$APP_ENV_DIR/cc-gateway" 2>/dev/null)" = "2" ] \
  && ok "cc-gateway has 2 export lines" || bad "cc-gateway export lines wrong"
( set +u; . "$APP_ENV_DIR/cc-api-fable"; [ "$ANTHROPIC_API_KEY" = "sk-ant-fable" ] ) \
  && ok "sourcing a per-app file exports its key to the child" || bad "per-app file does not export its key"
perms="$(stat -c '%a' "$APP_ENV_DIR/cc-api-fable" 2>/dev/null || stat -f '%Lp' "$APP_ENV_DIR/cc-api-fable")"
[ "$perms" = "600" ] \
  && ok "per-app file is 0600" || bad "per-app file perms (got: $perms)"

# 8. Guard the real step against a silent revert: it reads .agent_app_env, writes .agent-env.d/<slug>,
#    and EXPORTs the keys (a plain KEY=VALUE would not reach the sourced launch shell's claude child).
grep -qF 'agent_app_env // {} | keys[]' "$STEP" \
  && ok "19-secrets.sh reads .agent_app_env slugs" || bad "19-secrets.sh missing .agent_app_env slug filter"
grep -qF '${ENV_FILE}.d' "$STEP" \
  && ok "19-secrets.sh writes per-app files under \${ENV_FILE}.d" || bad "19-secrets.sh missing \${ENV_FILE}.d path"
grep -qF 'export ${key}=' "$STEP" \
  && ok "19-secrets.sh exports per-app keys" || bad "19-secrets.sh does not export per-app keys"

if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "All checks passed."
