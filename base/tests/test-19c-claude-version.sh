#!/usr/bin/env bash
# base/tests/test-19c-claude-version.sh — guard for the Claude Code version the
# 5-minute health report carries (base/assets/report-health-snapshot.sh,
# collect_claude_code_version → payload.dependency_versions.claude_code).
#
# The SideButton server's /health reports the Claude Code version it read once at
# startup, so after sb-self-update upgrades Claude Code (without a service restart)
# the portal kept showing the old version. The health report runs `claude --version`
# fresh every period and is the lane that keeps the portal current. Contract:
#   - a working claude       => dependency_versions == {"claude_code": "<x.y.z>"}
#   - claude missing, failing or printing no version => the key is OMITTED (absent
#     means "not reported"; the portal keeps its value) and the rest still posts.
#
# Hermetic: the python payload builder is extracted (as test-19c-auth-identity.sh
# does) and run with stub `claude` binaries first on PATH; the "no claude" case runs
# with a PATH holding only python3, so a real claude on the host is never reached.
# Pure bash; the payload assertions need jq + python3 (present on CI).
# Run: bash base/tests/test-19c-claude-version.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
REPORTER="$BASE/assets/report-health-snapshot.sh"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }
skip() { printf 'skip - %s\n' "$1"; }

# ── 0. static: syntax + the collector and the payload key are there ─────────────
bash -n "$REPORTER" && ok "bash -n: report-health-snapshot.sh" || bad "bash -n failed on the reporter"
grep -qF 'def collect_claude_code_version():' "$REPORTER" \
  && ok "collect_claude_code_version() present" || bad "collect_claude_code_version() missing"
grep -qF 'payload["dependency_versions"] = {"claude_code": ccv}' "$REPORTER" \
  && ok "payload builder emits dependency_versions.claude_code" || bad "dependency_versions missing from the payload builder"
grep -qE 'subprocess\.run\(\["claude", "--version"\].*timeout=' "$REPORTER" \
  && ok "claude --version runs with a timeout (a hung CLI cannot stall the report)" \
  || bad "claude --version is not bounded by a timeout"

if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  skip "jq/python3 not installed — skipping payload assertions (bash -n + greps ran)"
  echo; if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi; exit "$fail"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

BUILD="$TMP/build.py"
awk "/^python3 - << 'PYEOF'\$/{f=1;next} /^PYEOF\$/{f=0} f" "$REPORTER" > "$BUILD"
[ -s "$BUILD" ] && ok "extracted the python payload builder" || bad "could not extract the payload builder"

# ── stub claude binaries, one dir per behaviour ──────────────────────────────────
mkdir -p "$TMP/ok" "$TMP/fails" "$TMP/noversion" "$TMP/pyonly" "$TMP/home"
printf '#!/usr/bin/env bash\necho "2.1.280 (Claude Code)"\n'        > "$TMP/ok/claude"
printf '#!/usr/bin/env bash\necho "2.1.280 (Claude Code)"\necho "boom" >&2\nexit 1\n' > "$TMP/fails/claude"
printf '#!/usr/bin/env bash\necho "Claude Code"\n'                  > "$TMP/noversion/claude"
chmod +x "$TMP"/ok/claude "$TMP"/fails/claude "$TMP"/noversion/claude
ln -s "$(command -v python3)" "$TMP/pyonly/python3"
printf 'SIDEBUTTON_AGENT_NAME="x"\n' > "$TMP/env"

# run <out.json> <PATH> — the builder with a minimal, sandboxed environment.
run() {
  env -i PATH="$2" HOME="$TMP/home" ENV_FILE="$TMP/env" \
      SB_AUTH_CACHE_DIR="$TMP/cache" PAYLOAD_FILE="$1" \
      "$TMP/pyonly/python3" "$BUILD"
}
jqeq() { local got; got="$(jq -c "$2" "$1" 2>/dev/null)"; [ "$got" = "$3" ] && ok "$4" || bad "$4 (got: '$got')"; }

# ── 1. working claude => exactly {"claude_code": "2.1.280"} ──────────────────────
run "$TMP/p-ok.json" "$TMP/ok:$PATH"
jqeq "$TMP/p-ok.json" '.dependency_versions' '{"claude_code":"2.1.280"}' \
  "working claude => dependency_versions carries claude_code 2.1.280, nothing else"

# ── 2-4. no usable version => key omitted, the report still builds ──────────────
run "$TMP/p-fails.json" "$TMP/fails:$PATH"
jqeq "$TMP/p-fails.json" 'has("dependency_versions")' 'false' "claude exits non-zero (even after printing a version) => key omitted"
run "$TMP/p-nover.json" "$TMP/noversion:$PATH"
jqeq "$TMP/p-nover.json" 'has("dependency_versions")' 'false' "claude prints no x.y.z => key omitted"
run "$TMP/p-none.json" "$TMP/pyonly"
jqeq "$TMP/p-none.json" 'has("dependency_versions")' 'false' "no claude on PATH => key omitted"
for p in p-ok p-fails p-nover p-none; do
  jqeq "$TMP/$p.json" 'has("metrics") and has("processes")' 'true' "${p}: the rest of the report still builds"
done

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
