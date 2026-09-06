#!/usr/bin/env bash
# base/tests/test-19d-account-registry.sh — regression guard for the account
# knowledge-pack registry: base/19d-account-registry.sh + base/assets/sb-registry-sync.sh.
#
# WHY THIS GUARD EXISTS (KAN-150): the sync helper only ever ADDED a registry.
# `update` re-added $SIDEBUTTON_DEFAULT_REGISTRY when `registry list` lacked it, then
# pulled everything configured. The portal delivers that url on every env push and it
# CHANGES when an account switches from the hosted pack repo to a bring-your-own one —
# and the old registry stayed configured forever: both reinstalled their packs every
# 5-minute tick and overwrote each other's ~/.sidebutton/skills/<domain>/, and a pack
# key only the old registry carried never went away. Second defect: whenever
# SIDEBUTTON_DEFAULT_REGISTRY_TOKEN was set, the helper exported a GLOBAL
# credential.helper override, so with a GitHub registry url the PORTAL token answered
# github.com and the clone 401'd even though the gh helper (GH_TOKEN) would have worked.
#
# Contract under test:
#   * RECORD — `add`/`record` write ~/.sidebutton/account-registry (name= + url=, 0600);
#     the name is the one `sidebutton registry list` shows.
#   * SWITCH — a delivered url that differs from the record is reconciled
#     remove-then-add; unpushed commits in the old clone are bundled first.
#   * NO RECORD — a box provisioned before the record existed still reconciles, via a
#     NARROW fallback: only a configured url with the portal's per-account shape
#     (<git-host-base>/<digits>.git). A third-party registry is NEVER auto-removed.
#   * UNCHANGED — same url in, same `sidebutton` calls out as before the change
#     (add-if-missing, then pull), and a second update after a switch is silent.
#   * TOKEN — the override is HOST-SCOPED to the portal git host, and nothing is
#     exported when the token is empty or the registry url is not on that host.
#   * ROLLOUT — 19d is manifest-listed AND the asset it deploys is in the refresh
#     fingerprint, or an asset-only fix is change-gated out of the fleet (SCRUM-1626).
#
# Hermetic: no network, no root, no `sidebutton` — a FAKE binary on a sandbox PATH
# records every call and keeps the registry state. Uses the real `git` (present on
# every runner) only inside mktemp sandboxes. The ambient SIDEBUTTON_* of a live agent
# VM is scrubbed from every run, so this passes identically on a clean runner.
# Run: bash base/tests/test-19d-account-registry.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
SYNC="$BASE/assets/sb-registry-sync.sh"
STEP="$BASE/19d-account-registry.sh"
RUNSH="$BASE/run.sh"
MANIFEST="$BASE/refresh-manifest.txt"
HOSTED="https://git.sidebutton.com/4021.git"
OWNREPO="https://github.com/Kadmo-GmbH/kadmo-skills.git"
THIRD="https://github.com/acme/extra-packs.git"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# ── 0. validity ──────────────────────────────────────────────────────────────
[ -f "$SYNC" ] && ok "base/assets/sb-registry-sync.sh exists" || { bad "asset missing: $SYNC"; exit 1; }
[ -f "$STEP" ] && ok "base/19d-account-registry.sh exists"    || { bad "step missing: $STEP"; exit 1; }
bash -n "$SYNC" && ok "bash -n: sb-registry-sync.sh" || bad "bash -n failed on the sync helper"
bash -n "$STEP" && ok "bash -n: 19d-account-registry.sh" || bad "bash -n failed on the step"

# ── 1. rollout: the fix must reach ALREADY-PROVISIONED agents ────────────────
grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | grep -qx '19d-account-registry.sh' \
  && ok "refresh-manifest lists 19d (the step re-installs /opt/sb-registry-sync.sh)" \
  || bad "refresh-manifest is missing 19d — the helper would never be replaced on live agents"
grep -q '19d-account-registry.sh' "$RUNSH" \
  && ok "run.sh sources 19d (newly provisioned agents get it)" \
  || bad "run.sh does not source 19d"

# The helper is an ASSET 19d copies to /opt, so an edit to it leaves 19d's own bytes
# unchanged. Unless it is in the fingerprint's explicit list the change-gate skips the
# whole refresh and the fleet keeps the old copy (SCRUM-1626, same trap as sb-reboot).
(
  export SB_UPDATED_MARKER="$SANDBOX/updated" SB_SELF_UPDATE_BIN="$SANDBOX/sb-self-update.bin"
  export AGENT_USER="$(id -un)" AGENT_HOME="$SANDBOX/fp-home" SKIP_KNOWLEDGE_PACKS=1
  mkdir -p "$AGENT_HOME"
  # shellcheck source=../lib-refresh.sh
  . "$BASE/lib-refresh.sh"
  cp -r "$BASE" "$SANDBOX/tree"
  FP_BASE="$(sb_base_artifacts_fingerprint "$SANDBOX/tree")"
  printf '\n# drift\n' >> "$SANDBOX/tree/assets/sb-registry-sync.sh"
  FP_DRIFT="$(sb_base_artifacts_fingerprint "$SANDBOX/tree")"
  [ -n "$FP_BASE" ] && [ "$FP_DRIFT" != "$FP_BASE" ]
) >/dev/null 2>&1 \
  && ok "a sb-registry-sync-only edit flips the refresh fingerprint" \
  || bad "sb-registry-sync.sh is not in the fingerprint — an asset-only fix would never reach the fleet"

# 19d must write the record itself, so the REFRESH path (where `add` fails with
# "already exists") is what backfills boxes provisioned before the record existed.
grep -q 'SYNC_DEST} record' "$STEP" \
  && ok "19d writes the account-registry record at install" \
  || bad "19d never calls the helper's 'record' action — pre-KAN-150 boxes get no record"

# ── 2. the fake `sidebutton` + a run harness ─────────────────────────────────
FAKEBIN="$SANDBOX/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/sidebutton" <<'FAKE'
#!/usr/bin/env bash
# Fake `sidebutton` CLI: records every call, keeps registry state in $SB_STATE
# (one "<name>\t<url>" line per registry) and mirrors the real `registry list`
# rendering, exit codes and the "already exists" refusal.
set -uo pipefail
printf '%s\n' "$*" >> "$SB_CALLS"
{ printf '## %s\n' "$*"; env | grep -E '^(GIT_CONFIG_|GIT_TERMINAL_PROMPT)' | sort; } >> "$SB_ENV"
derive() {  # mirror of the CLI's deriveRegistryName()
  local u="$1" s n p c
  s="${u#https://}"; s="${s#http://}"; s="${s#git@}"; s="${s%.git}"
  n="$(printf '%s' "$s" | tr '/:' '--')"
  c="$(printf '%s' "$n" | tr '-' '\n' | grep -c .)"
  if [ "$c" -gt 2 ]; then
    case "$s" in *:*) p="${s#*:}" ;; *) p="${s#*/}" ;; esac
    [ -n "$p" ] && [ "$p" != "$s" ] && n="$(printf '%s' "$p" | tr '/' '-')"
  fi
  printf '%s' "$n" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-'
}
[ "${1:-}" = registry ] || { echo "fake: unsupported command $*" >&2; exit 64; }
touch "$SB_STATE"
case "${2:-}" in
  list)
    printf '\n  Skill Pack Registries\n\n'
    while IFS=$'\t' read -r n u; do
      [ -n "${n:-}" ] || continue
      printf '  %s (git) — enabled\n    URL: %s\n    Packs: 3\n\n' "$n" "$u"
    done < "$SB_STATE"
    ;;
  add)
    url="${3:?url}"; name="$(derive "$url")"
    if grep -qF "	${url}" "$SB_STATE" || cut -f1 "$SB_STATE" | grep -qx "$name"; then
      echo "  Registry '${name}' already exists. Remove it first or use --name." >&2
      exit 1
    fi
    [ "${SB_FAIL_ADD:-0}" = 1 ] && { echo "  git clone failed: fatal: Authentication failed" >&2; exit 1; }
    printf '%s\t%s\n' "$name" "$url" >> "$SB_STATE"
    mkdir -p "${HOME}/.sidebutton/registries/${name}"
    echo "  ✓ Registry added: ${name} (git)"
    ;;
  remove)
    name="${3:?name}"
    cut -f1 "$SB_STATE" | grep -qx "$name" || { echo "  Registry not found: ${name}" >&2; exit 1; }
    awk -F'\t' -v n="$name" '$1 != n' "$SB_STATE" > "$SB_STATE.new"
    mv "$SB_STATE.new" "$SB_STATE"
    rm -rf "${HOME}/.sidebutton/registries/${name}"
    echo "  ✓ Registry removed: ${name}"
    ;;
  update) echo "  ✓ updated" ;;
  *) echo "fake: unsupported registry subcommand ${2:-}" >&2; exit 64 ;;
esac
FAKE
chmod +x "$FAKEBIN/sidebutton"

H="$SANDBOX/home"
CASE_N=0
# setup_case <registry-url|-> <token|-> [name<TAB>url ...] — fresh HOME + state
setup_case() {
  local url="$1" token="$2"; shift 2
  CASE_N=$((CASE_N+1))
  rm -rf "$H"; mkdir -p "$H/.sidebutton/registries"
  : > "$SANDBOX/calls"; : > "$SANDBOX/env"; : > "$SANDBOX/state"
  local r
  # each extra arg is "<name> <url>" — stored as the tab-separated row the fake reads
  for r in "$@"; do printf '%s\t%s\n' "${r%% *}" "${r##* }" >> "$SANDBOX/state"; done
  {
    [ "$url" != "-" ] && printf 'SIDEBUTTON_DEFAULT_REGISTRY="%s"\n' "$url"
    [ "$token" != "-" ] && printf 'SIDEBUTTON_DEFAULT_REGISTRY_TOKEN="%s"\n' "$token"
  } > "$H/.agent-env"
}
# run_sync <action> [arg] — the helper, with the live VM's own SIDEBUTTON_* scrubbed
run_sync() {
  env -u SIDEBUTTON_DEFAULT_REGISTRY -u SIDEBUTTON_DEFAULT_REGISTRY_TOKEN \
      -u SIDEBUTTON_GIT_HOST_BASE -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
      -u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 \
      HOME="$H" PATH="$FAKEBIN:$PATH" SB_CALLS="$SANDBOX/calls" SB_ENV="$SANDBOX/env" \
      SB_STATE="$SANDBOX/state" SB_FAIL_ADD="${SB_FAIL_ADD:-0}" \
      bash "$SYNC" "$@" 2>&1
}
state_urls() { cut -f2 "$SANDBOX/state" | grep -c . ; }
has_url()    { cut -f2 "$SANDBOX/state" | grep -qxF "$1"; }
record()     { cat "$H/.sidebutton/account-registry" 2>/dev/null | tr '\n' ' '; }

# ── 3. the derived name matches the real CLI, byte for byte ─────────────────
# Golden values produced by @sidebutton/server's own deriveRegistryName().
setup_case "$OWNREPO" -
out="$(run_sync add "$OWNREPO")"
if grep -qx "name=kadmo-gmbh-kadmo-skills" "$H/.sidebutton/account-registry" 2>/dev/null; then
  ok "add records the name the CLI derives (kadmo-gmbh-kadmo-skills)"
else
  bad "add recorded the wrong registry name: $(record)"
fi
grep -qx "url=$OWNREPO" "$H/.sidebutton/account-registry" 2>/dev/null \
  && ok "add records the registry url" || bad "add did not record url=$OWNREPO: $(record)"
perm="$(stat -c '%a' "$H/.sidebutton/account-registry" 2>/dev/null)"
[ "$perm" = "600" ] && ok "the record is mode 0600" || bad "record mode is ${perm:-<missing>}, want 600"

# A re-run (the refresh path): the CLI refuses with "already exists" — the record
# must still be written, which is how pre-KAN-150 boxes are backfilled.
rm -f "$H/.sidebutton/account-registry"
run_sync record "$OWNREPO" >/dev/null
grep -qx "url=$OWNREPO" "$H/.sidebutton/account-registry" 2>/dev/null \
  && ok "'record' backfills the record for an already-configured registry" \
  || bad "'record' wrote no record for an already-configured registry"
if run_sync record "$THIRD" >/dev/null 2>&1; then
  bad "'record' wrote a record for a registry that is not configured"
else
  ok "'record' refuses a url that is not configured"
fi

# ── 4. no record + hosted → github switch (the pre-KAN-150 fleet) ────────────
setup_case "$OWNREPO" - "gitsidebuttoncom-4021 $HOSTED"
out="$(run_sync update)"
if [ "$(state_urls)" = "1" ] && has_url "$OWNREPO"; then
  ok "no record: the hosted registry is removed and the delivered one added (exactly one remains)"
else
  bad "no record: expected only $OWNREPO, got: $(tr '\n' ' ' < "$SANDBOX/state")"
fi
grep -q "registry remove gitsidebuttoncom-4021" "$SANDBOX/calls" \
  && ok "no record: the switch is a remove-then-add (packs of the old registry uninstalled)" \
  || bad "no record: no 'registry remove' was issued — the stale packs would linger"
grep -q "registry switched ${HOSTED} -> ${OWNREPO}" <<<"$out" \
  && ok "no record: logs 'registry switched <old> -> <new>'" \
  || bad "no record: missing the switch log line: $(tr '\n' ' ' <<<"$out")"
grep -qx "url=$OWNREPO" "$H/.sidebutton/account-registry" 2>/dev/null \
  && ok "no record: the record now names the new registry" || bad "no record: record not rewritten: $(record)"
[ ! -d "$H/.sidebutton/registries/gitsidebuttoncom-4021" ] \
  && ok "no record: the old clone is gone from ~/.sidebutton/registries/" \
  || bad "no record: the old clone survived the switch"

# Idempotent: a second update must say nothing about switching and remove nothing.
out2="$(run_sync update)"
grep -q "registry switched" <<<"$out2" \
  && bad "a second update still logs a switch (not idempotent)" \
  || ok "a second update after the switch logs nothing about switching"

# ── 5. record + switch with UNPUSHED commits → bundle first ─────────────────
setup_case "$OWNREPO" - "gitsidebuttoncom-4021 $HOSTED"
printf 'name=gitsidebuttoncom-4021\nurl=%s\n' "$HOSTED" > "$H/.sidebutton/account-registry"
chmod 0600 "$H/.sidebutton/account-registry"
CLONE="$H/.sidebutton/registries/gitsidebuttoncom-4021"
(
  set -e
  git init -q --bare "$SANDBOX/upstream.git"
  git init -q "$CLONE"
  cd "$CLONE"
  git config user.email t@example.com; git config user.name t
  git remote add origin "$SANDBOX/upstream.git"
  echo pushed > a.txt; git add -A; git commit -qm pushed
  git push -q origin HEAD:refs/heads/main
  git fetch -q origin
  echo local-only > b.txt; git add -A; git commit -qm "SD work never pushed"
) >/dev/null 2>&1
out="$(run_sync update)"
BUNDLE="$(ls "$H/.sidebutton"/registry-gitsidebuttoncom-4021-*.bundle 2>/dev/null | head -n1)"
if [ -n "$BUNDLE" ] && git bundle verify "$BUNDLE" >/dev/null 2>&1; then
  ok "unpushed commits are bundled to a verifiable ~/.sidebutton/registry-<name>-<date>.bundle"
else
  bad "no valid bundle was written before the old clone was removed"
fi
grep -qF "bundled to ${BUNDLE:-<none>}" <<<"$out" \
  && ok "the bundle path is logged" || bad "the bundle path was not logged: $(tr '\n' ' ' <<<"$out")"
if [ -n "$BUNDLE" ] && git bundle list-heads "$BUNDLE" 2>/dev/null | grep -q .; then
  ok "the bundle carries the refs (--all), so the unpushed work is recoverable"
else
  bad "the bundle has no refs — the unpushed work would be unrecoverable"
fi
[ "$(state_urls)" = "1" ] && has_url "$OWNREPO" \
  && ok "record + switch: exactly the delivered registry remains" \
  || bad "record + switch: expected only $OWNREPO, got: $(tr '\n' ' ' < "$SANDBOX/state")"

# A clone with NOTHING unpushed must not leave a bundle behind.
setup_case "$OWNREPO" - "gitsidebuttoncom-4021 $HOSTED"
printf 'name=gitsidebuttoncom-4021\nurl=%s\n' "$HOSTED" > "$H/.sidebutton/account-registry"
CLONE="$H/.sidebutton/registries/gitsidebuttoncom-4021"
( set -e
  git init -q "$CLONE"; cd "$CLONE"
  git config user.email t@example.com; git config user.name t
  git remote add origin "$SANDBOX/upstream.git"
  git fetch -q origin; git reset -q --hard origin/main 2>/dev/null || true
) >/dev/null 2>&1
run_sync update >/dev/null
ls "$H/.sidebutton"/registry-*.bundle >/dev/null 2>&1 \
  && bad "a bundle was written for a clone with no unpushed commits" \
  || ok "no bundle when the old clone has nothing unpushed"

# ── 6. record + UNCHANGED url → the old behaviour, byte for byte ────────────
setup_case "$OWNREPO" - "kadmo-gmbh-kadmo-skills $OWNREPO"
printf 'name=kadmo-gmbh-kadmo-skills\nurl=%s\n' "$OWNREPO" > "$H/.sidebutton/account-registry"
out="$(run_sync update)"
calls="$(tr '\n' '|' < "$SANDBOX/calls")"
[ "$calls" = "registry list|registry update|" ] \
  && ok "unchanged url: the same two calls as before (add-if-missing guard, then pull)" \
  || bad "unchanged url: call sequence drifted: ${calls}"
grep -qE "registry (switched|remove)" <<<"$out" \
  && bad "unchanged url: logged a switch" || ok "unchanged url: nothing is removed and nothing is logged as switched"

# Absent registry, unchanged url: the SCRUM-1167 self-heal must still fire.
setup_case "$OWNREPO" -
out="$(run_sync update)"
grep -q "configured registry absent — reconciling" <<<"$out" && has_url "$OWNREPO" \
  && ok "absent registry: add-if-missing still self-heals (SCRUM-1167)" \
  || bad "absent registry: the reconcile add did not happen"

# ── 7. a third-party registry is NEVER auto-removed ─────────────────────────
setup_case "$OWNREPO" - "acme-extra-packs $THIRD" "gitsidebuttoncom-4021 $HOSTED"
run_sync update >/dev/null
if has_url "$THIRD"; then
  ok "a third-party registry survives the switch (only the portal-shaped one is reaped)"
else
  bad "the third-party registry was auto-removed — only <git-host>/<digits>.git may be"
fi
grep -q "registry remove acme-extra-packs" "$SANDBOX/calls" \
  && bad "'registry remove' was issued for the third-party registry" \
  || ok "no remove is issued for a registry that is not the portal's per-account repo"
has_url "$HOSTED" && bad "the stale hosted registry survived" || ok "the stale hosted registry is still reaped"

# A url on the portal host that is NOT the per-account shape is not ours either.
setup_case "$OWNREPO" - "gitsidebuttoncom-shared-packs https://git.sidebutton.com/shared-packs.git"
run_sync update >/dev/null
has_url "https://git.sidebutton.com/shared-packs.git" \
  && ok "a portal-host url that is not <digits>.git is left alone" \
  || bad "a non-per-account portal url was removed — the shape guard is too loose"

# ── 8. the token override is host-scoped, and silent when it must not apply ──
scoped_keys() { grep -E '^GIT_CONFIG_KEY_[01]=' "$SANDBOX/env" | sort -u; }
setup_case "$HOSTED" "portal-tok" "gitsidebuttoncom-4021 $HOSTED"
printf 'name=gitsidebuttoncom-4021\nurl=%s\n' "$HOSTED" > "$H/.sidebutton/account-registry"
run_sync update >/dev/null
if [ "$(scoped_keys)" = "GIT_CONFIG_KEY_0=credential.https://git.sidebutton.com.helper
GIT_CONFIG_KEY_1=credential.https://git.sidebutton.com.helper" ]; then
  ok "token + hosted url: the override is scoped to credential.https://git.sidebutton.com.helper"
else
  bad "token + hosted url: unexpected GIT_CONFIG keys: $(scoped_keys | tr '\n' ' ')"
fi
grep -qE '^GIT_CONFIG_KEY_[0-9]+=credential\.helper$' "$SANDBOX/env" \
  && bad "a GLOBAL credential.helper override is still exported" \
  || ok "no global credential.helper override is exported any more"
grep -q 'GIT_CONFIG_VALUE_1=.*x-access-token' "$SANDBOX/env" \
  && ok "token + hosted url: the portal token still answers the portal host (pull keeps working)" \
  || bad "token + hosted url: no x-access-token helper was exported"
grep -q 'GIT_CONFIG_VALUE_1=.*portal-tok' "$SANDBOX/env" \
  && bad "the token VALUE was expanded into git config — it must resolve at call time" \
  || ok "the helper body keeps \$SIDEBUTTON_DEFAULT_REGISTRY_TOKEN unexpanded (rotation-safe)"

# Behaviour, not shape: replay what was exported through the REAL git and see which
# host it answers. This is the acceptance criterion — the portal token authenticates
# the portal host and is never offered to github.com.
cred_fill() {  # <host> — drive `git credential fill` with the exported GIT_CONFIG_*
  ( set -uo pipefail
    local k v
    while IFS='=' read -r k v; do [ -n "$k" ] && export "$k=$v"; done \
      < <(grep -E '^(GIT_CONFIG_[A-Z0-9_]+|GIT_TERMINAL_PROMPT)=' "$SANDBOX/env" | sort -u)
    printf 'protocol=https\nhost=%s\n\n' "$1" \
      | HOME="$H" GIT_CONFIG_GLOBAL="$H/.gitconfig" GIT_TERMINAL_PROMPT=0 \
        SIDEBUTTON_DEFAULT_REGISTRY_TOKEN=portal-tok git credential fill 2>/dev/null
  )
}
out="$(cred_fill git.sidebutton.com)"
if grep -qx 'username=x-access-token' <<<"$out" && grep -qx 'password=portal-tok' <<<"$out"; then
  ok "real git: the exported config authenticates git.sidebutton.com with the portal token"
else
  bad "real git: git.sidebutton.com did not resolve: $(tr '\n' ' ' <<<"$out")"
fi
out="$(cred_fill github.com)"
if grep -qx 'password=portal-tok' <<<"$out"; then
  bad "real git: the PORTAL token was offered to github.com — this is the 401 bug"
else
  ok "real git: github.com is never answered with the portal token (gh's helper is left to it)"
fi

# THE 401 BUG: token set, own-repo url — the portal token must never be offered to github.com.
setup_case "$OWNREPO" "portal-tok"
run_sync update >/dev/null
if grep -qE '^GIT_CONFIG_(COUNT|KEY_|VALUE_)' "$SANDBOX/env"; then
  bad "token + github url: a GIT_CONFIG override was exported — gh's GH_TOKEN helper is shadowed"
else
  ok "token + github url: nothing is exported (gh answers github.com with GH_TOKEN)"
fi
setup_case "$OWNREPO" "portal-tok"
out="$(run_sync add "$OWNREPO")"
grep -qE '^GIT_CONFIG_(COUNT|KEY_|VALUE_)' "$SANDBOX/env" \
  && bad "add: a GIT_CONFIG override leaks to a github.com clone" \
  || ok "add: no override for a github.com registry url (this is the 401 the ticket reports)"

# Empty token: no exports at all, on either host.
setup_case "$HOSTED" - "gitsidebuttoncom-4021 $HOSTED"
printf 'name=gitsidebuttoncom-4021\nurl=%s\n' "$HOSTED" > "$H/.sidebutton/account-registry"
run_sync update >/dev/null
grep -qE '^GIT_CONFIG_(COUNT|KEY_|VALUE_)|^GIT_TERMINAL_PROMPT=' "$SANDBOX/env" \
  && bad "empty token: GIT_CONFIG_* was still exported" \
  || ok "empty token: no GIT_CONFIG exports (nothing to force)"

# A white-label portal host is honoured for both the scope and the shape guard.
setup_case "-" "portal-tok" "gitexamplecom-77 https://git.example.com/77.git"
{
  printf 'SIDEBUTTON_GIT_HOST_BASE="https://git.example.com/"\n'
  printf 'SIDEBUTTON_DEFAULT_REGISTRY="%s"\n' "$OWNREPO"
  printf 'SIDEBUTTON_DEFAULT_REGISTRY_TOKEN="portal-tok"\n'
} > "$H/.agent-env"
run_sync update >/dev/null
has_url "https://git.example.com/77.git" \
  && bad "SIDEBUTTON_GIT_HOST_BASE was ignored — the white-label per-account repo was not reaped" \
  || ok "SIDEBUTTON_GIT_HOST_BASE (trailing slash and all) drives the per-account shape guard"

# ── 9. a failed add records nothing (so the next tick still reconciles) ──────
setup_case "$OWNREPO" -
SB_FAIL_ADD=1 run_sync add "$OWNREPO" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "a failed add exits non-zero (19d's WARN branch still fires)" \
                || bad "a failed add returned 0 — 19d would log success"
[ -f "$H/.sidebutton/account-registry" ] \
  && bad "a failed add wrote a record — a phantom record breaks switch detection" \
  || ok "a failed add records nothing"

# ── 10. no credential value at rest in the shipped asset ────────────────────
if sed 's/#.*//' "$SYNC" | grep -q "GIT_CONFIG_VALUE_1='"; then
  ok "the helper body is single-quoted (the token is read from the env at call time)"
else
  bad "GIT_CONFIG_VALUE_1 is not single-quoted — the token would be expanded at export time"
fi

echo
[ "$fail" = 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
