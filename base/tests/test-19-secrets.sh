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

if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "All checks passed."
