#!/usr/bin/env bash
# base/tests/test-19c-auth-identity.sh — regression guard for the SCRUM-1626
# auth-identity collector in base/assets/report-health-snapshot.sh.
#
# The reporter must extend the /api/agents/health-report payload with a NON-SECRET
# `auth_identity` block (design PROVIDER-AUTH-VISIBILITY.md §4.2/§4.3):
#   claude_subscription  — email/org/uuid8 from ~/.claude.json oauthAccount
#   global_env           — method subscription|api_key|gateway|none + token_fp + base_host
#   app_env_files        — inventory of ~/.agent-env.d/* (key names + fp + host; NO values)
#   cloud                — best-effort AWS (Bedrock) / GCP (Vertex) principals
#   collected_at         — ISO-8601 UTC
# Every section is best-effort: a single failure (missing/malformed file, offline
# `aws sts`) must still deliver the rest of the snapshot and never block the POST.
# Non-secret by construction: fingerprints only (first-6 + … + last-4), and the
# per-app token VALUES must never appear in the payload.
#
# Pure bash; the payload-shape assertions need jq + python3 (present on CI; a
# jq/py-less local run still proves bash -n + the presence greps). The test never
# touches the network or real cloud CLIs — aws/gcloud are stubbed on PATH and the
# cloud cache is redirected (SB_AUTH_CACHE_DIR) so it stays hermetic and offline.
# Run: bash base/tests/test-19c-auth-identity.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
REPORTER="$BASE/assets/report-health-snapshot.sh"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }
skip() { printf 'skip - %s\n' "$1"; }

# ── 0. the reporter must stay syntactically valid + carry the collector ──────────
bash -n "$REPORTER" && ok "bash -n: report-health-snapshot.sh" || bad "bash -n failed on the reporter"
grep -qF 'collect_auth_identity()' "$REPORTER" && ok "collect_auth_identity() present"    || bad "collect_auth_identity() missing"
grep -qF 'def fingerprint('        "$REPORTER" && ok "fingerprint() choke point present"   || bad "fingerprint() missing"
grep -qF '"auth_identity"'         "$REPORTER" && ok "payload builder emits auth_identity" || bad "auth_identity missing from the payload builder"
# ~/.claude/.credentials.json must NEVER be read — only ever named in a comment (§4.3).
if awk '/credentials/ && $0 !~ /^[[:space:]]*#/ {found=1} END{exit !found}' "$REPORTER"; then
  bad "'credentials' appears on a non-comment line — .credentials.json may be read"
else
  ok "AC6: ~/.claude/.credentials.json is never read (only named in comments)"
fi

# ── payload-shape assertions need jq + python3 ───────────────────────────────────
if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  skip "jq/python3 not installed — skipping payload-shape assertions (bash -n + greps ran)"
  echo; if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi; exit "$fail"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Extract the python payload builder (mirrors test-19c-terminal-capture.sh).
BUILD="$TMP/build.py"
awk "/^python3 - << 'PYEOF'\$/{f=1;next} /^PYEOF\$/{f=0} f" "$REPORTER" > "$BUILD"
[ -s "$BUILD" ] && ok "extracted the python payload builder" || bad "could not extract the payload builder"

# ── stubs on PATH (no network / no real cloud CLIs) ──────────────────────────────
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/aws" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_AWS_FAIL:-}" ] && { echo "sts: could not connect to the endpoint" >&2; exit 255; }
echo '{"UserId":"AIDAEXAMPLE","Account":"123456789012","Arn":"arn:aws:sts::123456789012:assumed-role/agent-runner/sess-42"}'
EOF
cat > "$BIN/gcloud" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"get-value account"*) echo "svc@my-proj.iam.gserviceaccount.com" ;;
  *"get-value project"*) echo "my-proj-42" ;;
esac
EOF
chmod +x "$BIN"/*

# Distinctive per-app tokens with an ASCII middle we can assert is never emitted.
FABLE_TOK="sk-ant-api03-FABLEMIDDLExyz-abcdWXYZ"; FABLE_MID="FABLEMIDDLE"
KIMI_TOK="sk-kimi-KIMIMIDDLEsecret-9990abcd";     KIMI_MID="KIMIMIDDLE"

# Fixture home: subscription + two app-env.d slugs -------------------------------
H="$TMP/home"; mkdir -p "$H/.agent-env.d"
cat > "$H/.claude.json" <<'EOF'
{"numStartups":7,"oauthAccount":{"emailAddress":"op1@company.com","organizationName":"Company","accountUuid":"1a2b3c4d-5e6f-7788-99aa-bbccddeeff00"}}
EOF
cat > "$H/.agent-env" <<'EOF'
SIDEBUTTON_AGENT_NAME="agent-x"
SIDEBUTTON_HOST=0.0.0.0
EOF
printf 'export ANTHROPIC_API_KEY="%s"\n' "$FABLE_TOK" > "$H/.agent-env.d/fable-api"
printf 'export ANTHROPIC_BASE_URL="https://api.kimi.com/v1"\nexport ANTHROPIC_AUTH_TOKEN="%s"\n' "$KIMI_TOK" > "$H/.agent-env.d/kimi-gw"

HE="$TMP/home-empty"; mkdir -p "$HE"          # no ~/.claude.json, no app envs

HB="$TMP/home-bad"; mkdir -p "$HB"            # malformed ~/.claude.json
printf '{ this is not valid json ' > "$HB/.claude.json"
cp "$H/.agent-env" "$HB/.agent-env"

# Fixture home for fingerprint edges: a <12-char token and a no-token app file ----
HF="$TMP/home-fp"; mkdir -p "$HF/.agent-env.d"; cp "$H/.agent-env" "$HF/.agent-env"
printf 'export ANTHROPIC_API_KEY="short99"\n'        > "$HF/.agent-env.d/tiny"     # 7 chars < 12
printf 'export SOME_OTHER_KEY="not-a-token-value"\n' > "$HF/.agent-env.d/no-token" # no anthropic token

# Global ENV_FILE variants (method derivation) ----------------------------------
printf 'ANTHROPIC_API_KEY="sk-ant-GLOBALKEYmid-1234pqrs"\n' > "$TMP/env-apikey"
printf 'ANTHROPIC_BASE_URL="https://api.moonshot.cn/anthropic"\nANTHROPIC_AUTH_TOKEN="sk-gw-GLOBALgwmid-9876abcd"\n' > "$TMP/env-gw"
printf 'ANTHROPIC_BASE_URL="http://127.0.0.1:3456"\nANTHROPIC_API_KEY="sk-ant-LOCALmid-0000zzzz"\n' > "$TMP/env-local"
printf 'SIDEBUTTON_AGENT_NAME="x"\n' > "$TMP/env-none"

# run <out.json> <home> <env_file> <cache_tag> [extra env KEY=VAL ...] ------------
run() {
  local out="$1" home="$2" envf="$3" tag="$4"; shift 4
  env -i PATH="$BIN:$PATH" HOME="$home" ENV_FILE="$envf" \
      SB_AUTH_CACHE_DIR="$TMP/cache-$tag" PAYLOAD_FILE="$out" "$@" \
      python3 "$BUILD"
}
jqeq() { local got; got="$(jq -r "$2" "$1")"; [ "$got" = "$3" ] && ok "$4" || bad "$4 (got: '$got')"; }

# ── 1. subscription + two app-env.d slugs (no cloud flags) ───────────────────────
P1="$TMP/p1.json"; run "$P1" "$H" "$H/.agent-env" sub
jqeq "$P1" '.auth_identity.claude_subscription.email'         'op1@company.com' "AC1: subscription email"
jqeq "$P1" '.auth_identity.claude_subscription.org'           'Company'         "AC1: subscription org"
jqeq "$P1" '.auth_identity.claude_subscription.account_uuid8' '1a2b3c4d'        "AC1: account_uuid8 (first 8 of uuid)"
jqeq "$P1" '.auth_identity.global_env.method'                 'subscription'    "AC3: method=subscription (no token, oauth present)"
jqeq "$P1" '.auth_identity.global_env.token_fp'               'null'            "AC3: subscription token_fp null"
jqeq "$P1" '.auth_identity.app_env_files | length'            '2'               "AC2: two app-env.d slugs inventoried"
jqeq "$P1" '.auth_identity.app_env_files[0].slug'             'fable-api'       "AC2: app files sorted by slug (fable-api first)"
jqeq "$P1" '.auth_identity.app_env_files[0].keys | join(",")' 'ANTHROPIC_API_KEY' "AC2: fable key names"
jqeq "$P1" '.auth_identity.app_env_files[0].base_host'        'null'            "AC2: fable base_host null (no base_url)"
jqeq "$P1" '.auth_identity.app_env_files[1].slug'             'kimi-gw'         "AC2: kimi-gw slug"
jqeq "$P1" '.auth_identity.app_env_files[1].keys | join(",")' 'ANTHROPIC_AUTH_TOKEN,ANTHROPIC_BASE_URL' "AC2: kimi key names sorted"
jqeq "$P1" '.auth_identity.app_env_files[1].base_host'        'api.kimi.com'    "AC2: kimi gateway base_host"
jqeq "$P1" '.auth_identity | has("cloud")'                    'false'           "cloud omitted when no Bedrock/Vertex flag"
jqeq "$P1" '.metrics | has("cpu_pct")'                        'true'            "metrics block still present (no regression)"
# fingerprint shape: first-6 + … + last-4 (values never emitted; asserted in 1b).
jqeq "$P1" '.auth_identity.app_env_files[0].token_fp | (startswith("sk-ant") and endswith("WXYZ") and contains("…"))' 'true' "AC6: fable token_fp = first-6 + … + last-4"
jqeq "$P1" '.auth_identity.app_env_files[1].token_fp | (startswith("sk-kim") and endswith("abcd") and contains("…"))' 'true' "AC6: kimi token_fp shape"
jqeq "$P1" '.auth_identity.collected_at | endswith("Z")'      'true'            "collected_at is ISO-8601 UTC"

# ── 1b. PRIVACY — no full per-app token (nor its middle) anywhere in the payload ──
priv=0
for needle in "$FABLE_TOK" "$FABLE_MID" "$KIMI_TOK" "$KIMI_MID"; do
  if grep -qF "$needle" "$P1"; then bad "PRIVACY LEAK: '$needle' present in payload"; priv=1; fi
done
[ "$priv" -eq 0 ] && ok "AC6: no full per-app token (or token middle) appears in the payload"

# ── 1c. fingerprint edges — <12-char token → last-2 only; no token → null ────────
PF="$TMP/pf.json"; run "$PF" "$HF" "$HF/.agent-env" fp
jqeq "$PF" '.auth_identity.app_env_files[] | select(.slug=="tiny")     | .token_fp | (endswith("99") and contains("…") and length==3)' 'true' "AC6: <12-char token renders last-2 only (…99)"
jqeq "$PF" '.auth_identity.app_env_files[] | select(.slug=="no-token") | .token_fp' 'null' "AC6: a slug with no anthropic token → token_fp null"
jqeq "$PF" '.auth_identity.app_env_files[] | select(.slug=="no-token") | .keys | join(",")' 'SOME_OTHER_KEY' "AC2: non-token key names still inventoried"

# ── 2. api_key — global ANTHROPIC_API_KEY, no base_url ───────────────────────────
P2="$TMP/p2.json"; run "$P2" "$HE" "$TMP/env-apikey" apikey
jqeq "$P2" '.auth_identity.global_env.method'    'api_key' "AC3: method=api_key (token, no base_url)"
jqeq "$P2" '.auth_identity.global_env.base_host' 'null'    "AC3: api_key base_host null"
jqeq "$P2" '.auth_identity.global_env.token_fp | contains("…")' 'true' "AC3: api_key token_fp emitted"

# ── 3. gateway — global token + NON-LOCAL base_url ───────────────────────────────
P3="$TMP/p3.json"; run "$P3" "$HE" "$TMP/env-gw" gw
jqeq "$P3" '.auth_identity.global_env.method'    'gateway'         "AC3: method=gateway (non-local base_url)"
jqeq "$P3" '.auth_identity.global_env.base_host' 'api.moonshot.cn' "AC3: gateway base_host"

# ── 4. LOCAL base_url (CCR proxy) is NOT a gateway → api_key, base_host null ──────
P4="$TMP/p4.json"; run "$P4" "$HE" "$TMP/env-local" local
jqeq "$P4" '.auth_identity.global_env.method'    'api_key' "AC3: 127.0.0.1 base_url ⇒ api_key, not gateway"
jqeq "$P4" '.auth_identity.global_env.base_host' 'null'    "AC3: local base_url yields no base_host"

# ── 5. none — no token, no oauth ─────────────────────────────────────────────────
P5="$TMP/p5.json"; run "$P5" "$HE" "$TMP/env-none" none
jqeq "$P5" '.auth_identity.global_env.method'            'none'  "AC3: method=none (no token, no oauth)"
jqeq "$P5" '.auth_identity | has("claude_subscription")' 'false' "AC1: claude_subscription omitted without oauthAccount"
jqeq "$P5" '.auth_identity | has("app_env_files")'       'false' "AC2: app_env_files omitted when ~/.agent-env.d absent"

# ── 6. Bedrock — flag + AWS_PROFILE, stubbed `aws sts` ───────────────────────────
P6="$TMP/p6.json"; run "$P6" "$H" "$H/.agent-env" bedrock CLAUDE_CODE_USE_BEDROCK=1 AWS_PROFILE=gs-prod
jqeq "$P6" '.auth_identity.cloud.aws_profile'  'gs-prod'                   "AC4: aws_profile from env"
jqeq "$P6" '.auth_identity.cloud.aws_account'  '123456789012'              "AC4: aws_account from sts"
jqeq "$P6" '.auth_identity.cloud.aws_arn_tail' 'assumed-role/agent-runner' "AC4: aws_arn_tail (role tail)"
jqeq "$P6" '.auth_identity.cloud.gcp_account'  'null'                      "AC4: gcp untouched on a Bedrock box"

# ── 7. Vertex — flag, stubbed `gcloud config` ────────────────────────────────────
P7="$TMP/p7.json"; run "$P7" "$H" "$H/.agent-env" vertex CLAUDE_CODE_USE_VERTEX=1
jqeq "$P7" '.auth_identity.cloud.gcp_account' 'svc@my-proj.iam.gserviceaccount.com' "AC4: gcp_account from gcloud"
jqeq "$P7" '.auth_identity.cloud.gcp_project' 'my-proj-42'                          "AC4: gcp_project from gcloud"
jqeq "$P7" '.auth_identity.cloud.aws_account' 'null'                                "AC4: aws untouched on a Vertex box"

# ── 8. partial failure — malformed ~/.claude.json + OFFLINE `aws sts` ────────────
#      still yields metrics + global_env + the aws_profile, and EXITS 0 (never blocks).
P8="$TMP/p8.json"
if run "$P8" "$HB" "$HB/.agent-env" partial CLAUDE_CODE_USE_BEDROCK=1 AWS_PROFILE=gs-prod STUB_AWS_FAIL=1; then
  ok "AC5: reporter exits 0 despite malformed .claude.json + offline aws"
else
  bad "AC5: reporter exited non-zero on a partial-collector failure (must never block the POST)"
fi
jqeq "$P8" '.metrics | has("cpu_pct")'                   'true'    "AC5: metrics still delivered on partial failure"
jqeq "$P8" '.auth_identity | has("claude_subscription")' 'false'   "AC5: malformed .claude.json ⇒ claude_subscription omitted"
jqeq "$P8" '.auth_identity | has("global_env")'          'true'    "AC5: global_env still delivered"
jqeq "$P8" '.auth_identity.cloud.aws_profile'            'gs-prod' "AC5: aws_profile kept even when sts is offline"
jqeq "$P8" '.auth_identity.cloud.aws_account'            'null'    "AC5: offline sts ⇒ aws_account null, not a crash"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
