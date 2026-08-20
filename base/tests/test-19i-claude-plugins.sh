#!/usr/bin/env bash
# base/tests/test-19i-claude-plugins.sh — regression guard for the Claude Code
# plugin install step (base/19i-claude-plugins.sh) and for the base/19b argv
# hardening that shipped with it (SCRUM-1982).
#
# Both halves live here because they are ONE contract: an operator-typed or
# catalog value must reach the CLI as an ARGV ELEMENT, never spliced into a
# string a shell re-parses. 19b was the precedent 19i had to not inherit, so its
# two assertions are section 8 rather than a file of their own.
#
# What this proves, in rough order of how much it would hurt to get wrong:
#   1. The step reaches the EXISTING fleet and evaluates the same on both paths.
#      19i must be sourced by run.sh AND listed in refresh-manifest.txt, and it
#      must not gate on a component signal — base/lib-refresh.sh never sources
#      components.sh, so INSTALL_CLAUDE_CODE is unset on the refresh path and a
#      component gate would silently skip the whole fleet while looking correct.
#   2. A name carrying shell metacharacters is rejected by the step's OWN
#      re-validation and never reaches an exec. The stub records every argv, so
#      "never reaches an exec" is asserted, not assumed.
#   3. A missing plugin is recorded, not fatal: `claude plugin install` exits 1,
#      the step is SOURCED under `set -euo pipefail`, and an unguarded call there
#      aborts the entire provision.
#   4. The marketplace alias is resolved by REPO, not by the label the operator
#      typed — the manifest names itself, so installing `name@operator-label`
#      fails for every pack whose manifest disagrees.
#   5. Idempotency is byte-level: a second run makes no install call and rewrites
#      the ledger identically, which is what makes the step safe on the routine
#      agent_pull_repos refresh cadence.
#
# Hermetic: pure bash + jq, no root, no network. `claude` and `su` are STUBBED on
# PATH (the test-19h jq-stub / test-19c pgrep-stub idiom); the `su` stub also
# proves the `-c 'exec "$@"' _ …` argv contract end to end, because it refuses to
# run anything whose -c body is not that exact literal.
# Run: bash base/tests/test-19i-claude-plugins.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
STEP="$BASE/19i-claude-plugins.sh"
STEP_19B="$BASE/19b-plugins.sh"
MANIFEST="$BASE/refresh-manifest.txt"
RUN="$BASE/run.sh"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Comment-stripped views. Both steps carry long prose headers that name the very
# strings these assertions look for, so grepping the raw file would pass on the
# strength of the COMMENT and a mutation that guts the code would still go green
# (the test-19g-agent-reboot.sh rule). Assert against code only.
STEP_CODE="$TMP/19i.code.sh"
STEP_19B_CODE="$TMP/19b.code.sh"
sed 's/^[[:space:]]*#.*$//' "$STEP"     > "$STEP_CODE"
sed 's/^[[:space:]]*#.*$//' "$STEP_19B" > "$STEP_19B_CODE"

# ── 0. validity ──────────────────────────────────────────────────────────────
[ -f "$STEP" ] && ok "base/19i-claude-plugins.sh exists" || bad "base/19i-claude-plugins.sh missing"
bash -n "$STEP"     2>/dev/null && ok "bash -n: 19i"  || bad "bash -n failed on 19i"
bash -n "$STEP_19B" 2>/dev/null && ok "bash -n: 19b"  || bad "bash -n failed on 19b"

# ── 1. fleet wiring ──────────────────────────────────────────────────────────
grep -qF '19i-claude-plugins.sh' "$RUN" && ok "run.sh sources 19i (new provisions)" || bad "run.sh does NOT source 19i"
awk '/19h-tmux-status.sh/{h=NR} /19i-claude-plugins.sh/{i=NR} /20-mark-installed.sh/{m=NR} END{exit !(h<i && i<m)}' "$RUN" \
  && ok "run.sh orders 19i after 19h and before 20-mark-installed" || bad "19i mis-ordered in run.sh"
grep -qxF '19i-claude-plugins.sh' <(sed -e 's/[[:space:]]*#.*$//' "$MANIFEST") \
  && ok "refresh-manifest.txt lists 19i (fleet reach without re-provisioning)" || bad "refresh-manifest.txt missing 19i"
# Manifest order is fingerprint order — keep it numeric so a re-order is not a phantom change.
awk '!/^[[:space:]]*#/ && NF {print}' "$MANIFEST" | awk '/19g-agent-reboot.sh/{g=NR} /19h-tmux-status.sh/{h=NR} /19i-claude-plugins.sh/{i=NR} END{exit !(g<h && h<i)}' \
  && ok "manifest keeps numeric (= fingerprint) order around 19i" || bad "manifest order around 19i is not numeric"
# The step ships NO base/assets/* file on purpose: the fingerprint's asset list in
# lib-refresh.sh is hard-coded, so an asset-only edit would not flip the fleet gate
# (SCRUM-1626). Everything 19i deploys must therefore be inline in the step.
if grep -Eq 'BASE_DIR"?/assets|assets/' "$STEP_CODE"; then
  bad "19i reads a base/assets file — an asset-only edit would not flip the refresh fingerprint"
else
  ok "19i keeps all logic inline (no asset outside the fingerprint)"
fi
# The refresh path re-runs manifest steps WITHOUT components.sh, so a component
# gate here evaluates differently at provision vs refresh and skips the fleet.
if grep -Eq 'has_component|AGENT_COMPONENTS|INSTALL_CLAUDE_CODE' "$STEP_CODE"; then
  bad "19i gates on a component signal — unavailable on the refresh path, would skip the fleet"
else
  ok "19i uses no component gate (gates on \`command -v claude\`, identical on both paths)"
fi
grep -q 'command -v claude' "$STEP_CODE" && ok "19i gates on \`command -v claude\`" || bad "19i has no \`command -v claude\` gate"

# ── 2. anti-regression: no interpolated command strings ──────────────────────
# `su -c "…$x…"` re-parses its argument as shell. Catch any -c body that both is
# double-quoted and carries an expansion, in either step.
for f in "$STEP_CODE" "$STEP_19B_CODE"; do
  n="$(basename "$f")"
  if grep -Eq '(su|runuser)[^\n]*-c[[:space:]]*"[^"]*\$' "$f"; then
    bad "${n}: interpolates an expansion into a su -c command string"
  else
    ok "${n}: no interpolated su -c command string"
  fi
done
# The `--` is not style. util-linux su permutes options past the username, so
# without a terminator it swallows the command's own flags (`--json`, `--depth`,
# `-d`) — and `-s user` worst of all, because `-s` IS an su option. Static check
# here, behavioural proof via the permuting stub below.
grep -qF -e "-c 'exec \"\$@\"' -- _" "$STEP_CODE"     && ok "19i uses the argv form, option-terminated (-c 'exec \"\$@\"' -- _ …)" || bad "19i is not using the option-terminated argv su form"
grep -qF -e "-c 'exec \"\$@\"' -- _" "$STEP_19B_CODE" && ok "19b uses the argv form, option-terminated (-c 'exec \"\$@\"' -- _ …)" || bad "19b is not using the option-terminated argv su form"

# ── 3. stubs ─────────────────────────────────────────────────────────────────
BIN="$TMP/bin"; mkdir -p "$BIN"

# `su` stub. Accepts ONLY the argv form the steps are required to use, so a
# regression to `su -c "string"` fails here loudly instead of silently working.
#
# It also models the half of util-linux `su` that a naive stub hides: GNU getopt
# PERMUTATION. Real su keeps scanning for its own options PAST the username, so
# without a `--` terminator it eats the command's flags — `mktemp -d` becomes
# `su: invalid option -- 'd'`, `claude plugin list --json` becomes `unrecognized
# option '--json'`, and `claude plugin install ref -s user` is worse still: `-s`
# is a real su option, silently swallowed as --shell so su tries to exec a shell
# named `user` and the flag never reaches the CLI. Every one of those failures
# looks like "the plugin just didn't install". Verified against util-linux
# 2.39.3 (Ubuntu 24.04, what the agents run). So: options before `--` are
# consumed here exactly as su would consume them, and an unknown one is fatal.
cat > "$BIN/su" <<'SUEOF'
#!/usr/bin/env bash
args=("$@"); operands=(); body=""; term=0; i=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  if [ "$term" -eq 0 ]; then
    case "$a" in
      --) term=1; i=$((i+1)); continue ;;
      -)  operands+=("$a"); i=$((i+1)); continue ;;        # the login dash is an operand
      -c|--command) body="${args[$((i+1))]:-}"; i=$((i+2)); continue ;;
      -s|--shell|-g|--group|-G|--supp-group|-w|--whitelist-environment)
          i=$((i+2)); continue ;;                          # option + its value
      -l|--login|-m|-p|--preserve-environment|-P|--pty|-f|--fast|-h|--help|-V|--version)
          i=$((i+1)); continue ;;
      -*) echo "su stub: unrecognized option '$a' — real su permutes past the username; terminate with '--'" >&2
          exit 96 ;;
    esac
  fi
  operands+=("$a"); i=$((i+1))
done
if [ "$body" != 'exec "$@"' ]; then
  echo "su stub: refusing a non-argv -c body: $body" >&2
  exit 97
fi
k=0
[ "${operands[$k]:-}" = "-" ] && k=$((k+1))   # login dash
k=$((k+1))                                    # username
if [ "${operands[$k]:-}" != "_" ]; then echo "su stub: no _ sentinel" >&2; exit 98; fi
exec "${operands[@]:$((k+1))}"
SUEOF
chmod +x "$BIN/su"

# `claude` stub. Records EVERY invocation's argv (tab-separated, one line each)
# and answers the three `claude plugin` calls from flat state files.
#   CC_MKT_STATE      NDJSON  {name, source, repo}
#   CC_INST_STATE     NDJSON  {id, version, scope, enabled}
#   CC_MANIFEST_NAMES TSV     owner/repo<TAB>manifest-name   (default: basename)
#   CC_MISSING        lines   plugin names the marketplace does not carry
cat > "$BIN/claude" <<'CLAUDEEOF'
#!/usr/bin/env bash
{ printf 'ARGV'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$CC_LOG"
if [ "${1:-}" != "plugin" ]; then exit 0; fi
shift
if [ "${1:-}" = "marketplace" ]; then
  shift
  case "${1:-}" in
    list) jq -s '.' "$CC_MKT_STATE" 2>/dev/null || echo '[]' ;;
    add)
      src="${2:-}"
      name="$(awk -F'\t' -v r="$src" '$1==r{print $2}' "$CC_MANIFEST_NAMES" 2>/dev/null | head -1)"
      [ -n "$name" ] || name="$(basename "$src" | tr '[:upper:]' '[:lower:]')"
      if ! jq -e --arg r "$src" 'select(.repo==$r)' "$CC_MKT_STATE" >/dev/null 2>&1; then
        jq -nc --arg n "$name" --arg r "$src" '{name:$n, source:"github", repo:$r}' >> "$CC_MKT_STATE"
      fi
      echo "Successfully added marketplace: $name" ;;
    *) exit 0 ;;
  esac
  exit 0
fi
case "${1:-}" in
  list) jq -s '.' "$CC_INST_STATE" 2>/dev/null || echo '[]' ;;
  install)
    ref="${2:-}"; name="${ref%@*}"; mkt="${ref##*@}"
    if ! jq -e --arg m "$mkt" 'select(.name==$m)' "$CC_MKT_STATE" >/dev/null 2>&1; then
      echo "Failed to install plugin \"$ref\": Plugin \"$name\" not found in marketplace \"$mkt\"." >&2
      exit 1
    fi
    if grep -qxF "$name" "$CC_MISSING" 2>/dev/null; then
      # Reason FIRST, then a long transcript — the real CLI's shape. The step has to
      # keep the head when it bounds this to 300 bytes; keeping the tail stores only
      # the noise, which is what the operator gets in the chip tooltip.
      echo "Failed to install plugin \"$ref\": Plugin \"$name\" not found in marketplace \"$mkt\"." >&2
      # CC_VERBOSE_FAIL: pad past the 64K pipe buffer. A bound taken with a
      # reader that exits early (`| head -c 300`) makes the writer ahead of it
      # die of SIGPIPE, which `set -o pipefail` turns into a failed assignment
      # and `set -e` turns into an aborted provision. 20 lines cannot reach that;
      # 6000 can.
      _pad=20
      [ "${CC_VERBOSE_FAIL:-0}" = "1" ] && _pad=6000
      for _n in $(seq 1 "$_pad"); do
        echo "  at step ${_n}: resolving manifest entries, this line is padding to push the reason out of a 300-byte tail window" >&2
      done
      exit 1
    fi
    if ! jq -e --arg i "$ref" 'select(.id==$i)' "$CC_INST_STATE" >/dev/null 2>&1; then
      jq -nc --arg i "$ref" '{id:$i, version:"1.0.0", scope:"user", enabled:true}' >> "$CC_INST_STATE"
    fi
    echo "Successfully installed plugin: $ref" ;;
  *) exit 0 ;;
esac
exit 0
CLAUDEEOF
chmod +x "$BIN/claude"

command -v jq >/dev/null 2>&1 && ok "jq available (the guard needs a real one)" || bad "jq missing — cannot run the behavioural cases"

# ── 4. harness ───────────────────────────────────────────────────────────────
new_box() {                       # → echoes a fresh fake $AGENT_HOME
  # mktemp, not a counter: this runs inside $(…), so a shell variable bumped here
  # would never survive back to the caller and every "fresh" box would be one box.
  local h; h="$(mktemp -d "$TMP/box.XXXXXX")"
  mkdir -p "$h/.sidebutton" "$h/.claude"
  printf 'AGENT_NAME="euler"\n' > "$h/.agent-env"
  : > "$h/mkt.ndjson"; : > "$h/inst.ndjson"; : > "$h/names.tsv"; : > "$h/missing.txt"
  printf '%s' "$h"
}

run_step() {                      # run_step <box> [CLAUDE_PLUGINS] [CLAUDE_PLUGIN_MARKETPLACES]
  local h="$1"
  : > "$h/claude.log"
  (
    set -euo pipefail
    export PATH="$BIN:$PATH"
    export LOG_FILE="$TMP/install.log"
    export AGENT_USER="$(id -un)"
    export AGENT_HOME="$h"
    export BASE_DIR="$BASE"
    export CC_LOG="$h/claude.log" CC_MKT_STATE="$h/mkt.ndjson" CC_INST_STATE="$h/inst.ndjson"
    export CC_MANIFEST_NAMES="$h/names.tsv" CC_MISSING="$h/missing.txt"
    export CLAUDE_PLUGINS="${2-}" CLAUDE_PLUGIN_MARKETPLACES="${3-}"
    # shellcheck source=../lib.sh
    . "$BASE/lib.sh"
    # shellcheck source=../19i-claude-plugins.sh
    . "$STEP"
  ) >"$h/run.out" 2>&1
}

ledger()  { cat "$1/.sidebutton/claude-plugins.json" 2>/dev/null; }
status_of() { jq -r --arg n "$2" '.[]|select(.name==$n)|.status' "$1/.sidebutton/claude-plugins.json" 2>/dev/null; }
installs()  { grep -c $'\tinstall\t' "$1/claude.log" 2>/dev/null || true; }

# ── 5. install path: 3 refs ⇒ 3 installed ────────────────────────────────────
B="$(new_box)"
printf '%s\n' '{"name":"claude-plugins-official","source":"github","repo":"anthropics/claude-plugins-official"}' > "$B/mkt.ndjson"
if run_step "$B" 'alpha,beta,gamma'; then ok "install path: step exits 0 under set -euo pipefail"; else bad "install path: step aborted (rc=$?) — would abort provisioning"; fi
if [ "$(jq -r '[.[]|select(.status=="installed")]|length' <<<"$(ledger "$B")" 2>/dev/null)" = "3" ]; then
  ok "install path: all 3 requested plugins recorded status=installed"
else
  bad "install path: ledger wrong: $(ledger "$B")"
fi
jq -e '.[0]|has("name") and has("marketplace") and has("status") and has("version") and has("error")' <<<"$(ledger "$B")" >/dev/null 2>&1 \
  && ok "ledger entries carry {name, marketplace, status, version, error}" || bad "ledger entry shape wrong"
[ "$(jq -r '.[0].version' <<<"$(ledger "$B")")" = "1.0.0" ] \
  && ok "version comes from \`claude plugin list --json\`, not install stdout" || bad "version not taken from the plugin list"
grep -q '^CLAUDE_PLUGINS="alpha@claude-plugins-official,beta@claude-plugins-official,gamma@claude-plugins-official"$' "$B/.agent-env" \
  && ok "normalised request persisted to ~/.agent-env (refresh re-run + self-heal)" || bad "~/.agent-env persist missing/incorrect: $(grep CLAUDE "$B/.agent-env" 2>/dev/null)"

# ── 6. idempotency: second run installs nothing, ledger byte-identical ───────
before="$(sha256sum "$B/.sidebutton/claude-plugins.json" | awk '{print $1}')"
run_step "$B" 'alpha,beta,gamma'
after="$(sha256sum "$B/.sidebutton/claude-plugins.json" | awk '{print $1}')"
[ "$before" = "$after" ] && ok "idempotent: ledger byte-identical on a no-change run" || bad "ledger churned on a no-change run"
[ "$(installs "$B")" = "0" ] && ok "change-gate: second run makes NO install call" || bad "second run still called install ($(installs "$B")x)"
env_lines="$(grep -c '^CLAUDE_PLUGINS=' "$B/.agent-env")"
[ "$env_lines" = "1" ] && ok "~/.agent-env is updated in place, not appended to" || bad "~/.agent-env grew a duplicate CLAUDE_PLUGINS line ($env_lines)"

# ── 7. no-op path: empty CLAUDE_PLUGINS ⇒ no exec, no ledger ────────────────
B2="$(new_box)"
run_step "$B2" ''
[ ! -f "$B2/.sidebutton/claude-plugins.json" ] && ok "no-op path: empty request writes no ledger" || bad "no-op path wrote a ledger"
[ ! -s "$B2/claude.log" ] && ok "no-op path: the CLI is never invoked" || bad "no-op path invoked claude: $(cat "$B2/claude.log")"
grep -q 'none requested' "$B2/run.out" && ok "no-op path logs 'none requested'" || bad "no-op path did not log the skip"

# ── 8. bad-name path: rejected, and NEVER executed ──────────────────────────
B3="$(new_box)"
printf '%s\n' '{"name":"claude-plugins-official","source":"github","repo":"anthropics/claude-plugins-official"}' > "$B3/mkt.ndjson"
EVIL='foo;id'
if run_step "$B3" "alpha,${EVIL},beta"; then ok "bad-name path: step exits 0"; else bad "bad-name path aborted the step"; fi
[ "$(status_of "$B3" "$EVIL")" = "rejected" ] && ok "bad-name path: '${EVIL}' recorded status=rejected" || bad "bad-name path: not recorded as rejected: $(ledger "$B3")"
if grep -qF "$EVIL" "$B3/claude.log"; then
  bad "bad-name path: '${EVIL}' REACHED an exec — $(grep -F "$EVIL" "$B3/claude.log" | head -1)"
else
  ok "bad-name path: '${EVIL}' never reached an exec (zero invocations carry it)"
fi
[ "$(status_of "$B3" alpha)" = "installed" ] && [ "$(status_of "$B3" beta)" = "installed" ] \
  && ok "bad-name path: the good entries around it still installed" || bad "bad-name path aborted the rest of the list"
grep -qF "$EVIL" "$B3/.agent-env" && bad "bad-name path: the rejected token was persisted to ~/.agent-env" \
  || ok "bad-name path: only validated refs are persisted to ~/.agent-env"
# The marketplace half of the request is re-validated too.
B3b="$(new_box)"
run_step "$B3b" 'alpha@evil;mkt'
[ "$(status_of "$B3b" 'alpha@evil;mkt')" = "rejected" ] && ok "a metacharacter in the MARKETPLACE half is rejected too" || bad "bad marketplace not rejected: $(ledger "$B3b")"
grep -qF 'evil;mkt' "$B3b/claude.log" && bad "the bad marketplace reached an exec" || ok "the bad marketplace never reached an exec"

# ── 9. missing-plugin path: failed + error captured, rest still processed ────
B4="$(new_box)"
printf '%s\n' '{"name":"claude-plugins-official","source":"github","repo":"anthropics/claude-plugins-official"}' > "$B4/mkt.ndjson"
printf 'ghost\n' > "$B4/missing.txt"
if run_step "$B4" 'alpha,ghost,beta'; then ok "missing-plugin path: a non-zero install does not abort the step"; else bad "missing-plugin path aborted the step (rc=$?)"; fi
[ "$(status_of "$B4" ghost)" = "failed" ] && ok "missing plugin recorded status=failed" || bad "missing plugin not recorded as failed: $(ledger "$B4")"
jq -e '.[]|select(.name=="ghost")|.error|test("not found in marketplace")' <<<"$(ledger "$B4")" >/dev/null 2>&1 \
  && ok "the CLI's own error is captured in the ledger" || bad "the install error was not captured"
# The stub's failure is reason-first then 20 lines of padding, so a tail-truncation
# keeps only the padding. That string IS the chip tooltip the agent-detail copy tells
# the operator to hover, and both readers slice(0,300) from the front — so the step
# has to bound it from the front too.
jq -e '.[]|select(.name=="ghost")|.error|startswith("Failed to install plugin")' <<<"$(ledger "$B4")" >/dev/null 2>&1 \
  && ok "a long CLI error is truncated from the FRONT, keeping the reason" \
  || bad "the error was truncated from the wrong end — reason lost: $(jq -r '.[]|select(.name=="ghost")|.error' <<<"$(ledger "$B4")")"
[ "$(status_of "$B4" beta)" = "installed" ] \
  && ok "entries AFTER the failure are still processed" || bad "the failure stopped the rest of the list"

# A VERBOSE failure — bigger than the 64K pipe buffer — must still be recorded,
# not fatal. This is not a variant of the case above: bounding the message with
# `… | head -c 300` makes the reader close the pipe first, so sed dies of
# SIGPIPE, and under `set -o pipefail` that non-zero pipeline lands in an
# ASSIGNMENT, which `set -e` does not forgive. The step is SOURCED, so the whole
# provision aborts at 19i — no ledger, and 20-mark-installed never runs. The
# stub's 20 padding lines above are ~2K and stay inside the buffer, so only a
# payload this size exercises it.
#
# It must run in a REAL script shell. Job control (`set -m`, on in an
# interactive/`-c` parent) changes the outcome, so a case that passes when driven
# by hand can still abort a cloud-init provision. `bash <file>` is how run.sh is
# actually executed.
B4b="$(new_box)"
printf '%s\n' '{"name":"claude-plugins-official","source":"github","repo":"anthropics/claude-plugins-official"}' > "$B4b/mkt.ndjson"
printf 'ghost\n' > "$B4b/missing.txt"
: > "$B4b/claude.log"
cat > "$B4b/driver.sh" <<DRVEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$BIN:\$PATH"
export LOG_FILE="$TMP/install.log" AGENT_USER="$(id -un)" AGENT_HOME="$B4b" BASE_DIR="$BASE"
export CC_LOG="$B4b/claude.log" CC_MKT_STATE="$B4b/mkt.ndjson" CC_INST_STATE="$B4b/inst.ndjson"
export CC_MANIFEST_NAMES="$B4b/names.tsv" CC_MISSING="$B4b/missing.txt" CC_VERBOSE_FAIL=1
export CLAUDE_PLUGINS='ghost,beta'
. "$BASE/lib.sh"
. "$STEP"
echo "REACHED-THE-NEXT-STEP"
DRVEOF
if bash "$B4b/driver.sh" >"$B4b/run.out" 2>&1; then
  ok "a >64K CLI error does not abort the sourced provision"
else
  bad "a >64K CLI error aborted the provision (rc=$?) — 20-mark-installed would never run"
fi
grep -q 'REACHED-THE-NEXT-STEP' "$B4b/run.out" \
  && ok "provisioning continues past 19i after a verbose failure" || bad "the step never returned — provisioning stopped at 19i"
[ "$(status_of "$B4b" ghost)" = "failed" ] && ok "the verbose failure is still recorded as failed" || bad "verbose failure not recorded: $(ledger "$B4b")"
jq -e '.[]|select(.name=="ghost")|.error|startswith("Failed to install plugin") and (length<=300)' <<<"$(ledger "$B4b")" >/dev/null 2>&1 \
  && ok "a verbose error is bounded to 300 chars, reason first" || bad "verbose error not bounded/reason lost: $(jq -r '.[]|select(.name=="ghost")|.error|length' <<<"$(ledger "$B4b")" 2>/dev/null)"
[ "$(status_of "$B4b" beta)" = "installed" ] \
  && ok "entries after a verbose failure are still processed" || bad "the verbose failure stopped the rest of the list"

# ── 10. marketplace add + alias resolved by REPO, not by the operator's label ─
# The manifest names itself: `marketplace add Acme/claude-packs` registers
# `acme-packs`, whatever the operator called it. Installing `name@acme-alias`
# would fail; the step must install `name@acme-packs` and still report the
# REQUESTED alias in the ledger.
B5="$(new_box)"
printf 'Acme/claude-packs\tacme-packs\n' > "$B5/names.tsv"
run_step "$B5" 'helper@acme-alias' 'acme-alias=Acme/claude-packs'
grep -q $'\tmarketplace\tadd\tAcme/claude-packs$' "$B5/claude.log" \
  && ok "marketplace add ran with the source as a single argv element" || bad "marketplace add argv wrong: $(grep marketplace "$B5/claude.log" | head -2)"
grep -q $'\tinstall\thelper@acme-packs\t' "$B5/claude.log" \
  && ok "install resolved the alias by REPO (helper@acme-packs, not @acme-alias)" || bad "alias not reconciled: $(grep install "$B5/claude.log" | head -2)"
[ "$(status_of "$B5" helper)" = "installed" ] && ok "renamed-marketplace plugin recorded installed" || bad "renamed-marketplace plugin not installed: $(ledger "$B5")"
[ "$(jq -r '.[0].marketplace' <<<"$(ledger "$B5")")" = "acme-alias" ] \
  && ok "the ledger reports the REQUESTED alias (what the portal stored)" || bad "ledger marketplace is not the requested alias"
# A marketplace source that is not owner/repo must never reach `marketplace add`.
B6="$(new_box)"
run_step "$B6" 'helper@bad-mkt' 'bad-mkt=not a repo; rm -rf /'
grep -qE 'rm ?-rf' "$B6/claude.log" && bad "an invalid marketplace source reached an exec" || ok "an invalid marketplace source never reached an exec"
[ "$(status_of "$B6" helper)" = "failed" ] \
  && ok "a plugin whose marketplace could not be added is failed, not fatal" || bad "unusable marketplace not reported: $(ledger "$B6")"

# ── 11. no claude CLI on the box ⇒ clean skip ───────────────────────────────
B7="$(new_box)"
# A PATH that genuinely has no `claude` on it — this very box has a real one in
# /usr/bin, so trimming PATH to the system dirs would NOT exercise the gate. Farm
# every system executable except `claude` into a temp dir instead.
NOCLAUDE="$TMP/noclaude"; mkdir -p "$NOCLAUDE"
for d in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    [ "$b" = "claude" ] && continue
    [ -e "$NOCLAUDE/$b" ] || ln -s "$f" "$NOCLAUDE/$b" 2>/dev/null || true
  done
done
# The farm loop above already symlinked the system `su` here; `cp` over that
# symlink would write through it to /usr/bin/su (permission denied, and noise on
# stderr). Replace the link with our own stub instead.
ln -sf "$BIN/su" "$NOCLAUDE/su"
command -v claude >/dev/null 2>&1 && PATH="$NOCLAUDE" command -v claude >/dev/null 2>&1 \
  && bad "the no-claude PATH still resolves claude — case 11 proves nothing"
if (
  set -euo pipefail
  export PATH="$NOCLAUDE"
  export LOG_FILE="$TMP/install.log" AGENT_USER="$(id -un)" AGENT_HOME="$B7" BASE_DIR="$BASE"
  export CLAUDE_PLUGINS='alpha'
  . "$BASE/lib.sh"; . "$STEP"
) >"$B7/run.out" 2>&1; then
  grep -q 'no Claude Code CLI' "$B7/run.out" && ok "no claude on the box ⇒ clean skip" || bad "no-claude skip did not log its reason"
else
  bad "no-claude path aborted the step"
fi
[ ! -f "$B7/.sidebutton/claude-plugins.json" ] && ok "no claude ⇒ no ledger written" || bad "no-claude path wrote a ledger"

# ── 12. base/19b hardening (the same argv contract, SCRUM-1982) ─────────────
grep -q 'PLUGIN_REPO_RE\|PLUGIN_REF_RE' "$STEP_19B_CODE" \
  && ok "19b pattern-checks the catalog repo/ref before use" || bad "19b has no strict pattern check on repo/ref"
grep -q 'PLUGIN_APT_RE' "$STEP_19B_CODE" \
  && ok "19b pattern-checks every system_deps token before apt-get" || bad "19b has no strict pattern check on system_deps"
if grep -Eq 'apt-get install[^\n]*\$[a-z_]+[^"]*$|apt-get install[^\n]*\$\{[a-z_]+\}[^"]*$' "$STEP_19B_CODE"; then
  bad "19b still word-splits an unquoted catalog value into a root apt-get"
else
  ok "19b passes system deps to apt-get as an argv array, not a split string"
fi
grep -q 'clone_args=(' "$STEP_19B_CODE" \
  && ok "19b builds its git clone as an argv array" || bad "19b does not build git clone as an argv array"
grep -q 'SC2086' "$STEP_19B_CODE" \
  && bad "19b still carries a word-splitting shellcheck suppression" || ok "19b no longer needs the SC2086 suppression"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
