#!/bin/bash
# /opt/sb-registry-sync.sh
#
# Add, RECONCILE and update the per-account knowledge-pack registry. Shared by the
# one-time install add (base/19d) and the recurring update timer
# (sb-registry-update.timer) so both authenticate a private registry repo identically.
#
# Usage: sb-registry-sync.sh add [registry-url]      # url falls back to $SIDEBUTTON_DEFAULT_REGISTRY
#        sb-registry-sync.sh record [registry-url]   # (re)write the account-registry record only
#        sb-registry-sync.sh update                  # reconcile, then git-pull every git registry
#
# `add` clones the registry git repo once; `update` reconciles the configured set
# against what the portal is delivering and then pulls it, so agents pick up
# SD-pushed modules.
#
# Auth (optional): SIDEBUTTON_DEFAULT_REGISTRY_TOKEN from ~/.agent-env. The env
# file is sourced at CALL time — secrets land AFTER boot (base/19 / portal
# config-apply) and systemd reads its EnvironmentFile only at start, so reading
# ~/.agent-env on every run is what always sees the current token and dodges the
# could-not-read-Username timing failure class (cf. SCRUM-1122/1124, base/12b).
#
# ── WHY THIS DOES MORE THAN add-if-missing (KAN-150) ─────────────────────────
# The portal delivers SIDEBUTTON_DEFAULT_REGISTRY on every env push, and that URL
# CHANGES when an account switches from the portal-hosted pack repo
# (https://git.sidebutton.com/<id>.git) to a bring-your-own GitHub repo. This script
# used to only ever ADD, so after a switch BOTH registries stayed configured: each
# reinstalled its packs on every 5-minute tick and overwrote the other's
# ~/.sidebutton/skills/<domain>/ directories, and any pack key that only the old
# registry carried lingered forever. Switching is remove-then-add — that is what
# uninstalls the old registry's packs — so `update` now reconciles:
#
#   1. ~/.sidebutton/account-registry records WHICH registry is the account's
#      (name= + url=, 0600). `add` and `record` write it; `update` reads it.
#   2. A recorded url that differs from the delivered one is a switch: bundle any
#      unpushed work, `sidebutton registry remove <name>`, re-add, rewrite the record.
#   3. Boxes provisioned before the record existed get a narrow fallback: a
#      configured registry whose url has the PORTAL's per-account shape
#      (<git-host-base>/<digits>.git) and is not what the portal is delivering can
#      only be a previous account registry. Nothing else is ever auto-removed — a
#      third-party registry an operator added by hand is never touched. This sweep
#      is deliberately not gated on "no record": the record can also be written
#      (by base/19d, on a refresh) AFTER a switch already stacked the two, and the
#      stale portal clone must still be reaped.
#
# ── WHY THE TOKEN OVERRIDE IS HOST-SCOPED ────────────────────────────────────
# This script used to export a GLOBAL credential.helper override (GIT_CONFIG_KEY_0/1)
# for every git child of `sidebutton registry add|update` whenever the token was set.
# With a GitHub registry url that helper answered github.com with the PORTAL token, so
# the clone failed 401 even though the `gh` helper (GH_TOKEN) would have worked. The
# override is now scoped to the portal git host only (same allowlist shape as base/12b,
# which already wires credential.https://git.sidebutton.com.helper for the push side),
# and nothing is exported when the token is empty or no portal-hosted url is in play.
# `gh`'s helper then handles github.com with GH_TOKEN as designed.

set -uo pipefail

ACTION="${1:-update}"
HOME_DIR="${HOME:-/home/agent}"
ENV_FILE="${HOME_DIR}/.agent-env"
SB_DIR="${HOME_DIR}/.sidebutton"
RECORD_FILE="${SB_DIR}/account-registry"
CLONES_DIR="${SB_DIR}/registries"
log() { echo "$(date -Is) sb-registry-sync[$ACTION] $*"; }

# Source the agent env at call time (systemd EnvironmentFile format: KEY="VALUE").
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
else
  log "WARN: $ENV_FILE not found — proceeding with process env only" >&2
fi

# The portal's git host. Prod is git.sidebutton.com; a white-label deploy can
# override it by delivering SIDEBUTTON_GIT_HOST_BASE in ~/.agent-env.
PORTAL_GIT_BASE="${SIDEBUTTON_GIT_HOST_BASE:-https://git.sidebutton.com}"
while [ "${PORTAL_GIT_BASE%/}" != "$PORTAL_GIT_BASE" ]; do PORTAL_GIT_BASE="${PORTAL_GIT_BASE%/}"; done

# ── url helpers ──────────────────────────────────────────────────────────────
url_host() {  # https://host/path -> host  (empty for anything not http(s))
  case "$1" in
    https://*) local h="${1#https://}"; printf '%s' "${h%%/*}" ;;
    http://*)  local h="${1#http://}";  printf '%s' "${h%%/*}" ;;
    *)         printf '' ;;
  esac
}

is_portal_url() {  # on the portal git host at all
  case "$1" in "${PORTAL_GIT_BASE}"/*) return 0 ;; *) return 1 ;; esac
}

is_portal_account_url() {  # the portal's per-account repo shape: <base>/<digits>.git
  local rest
  case "$1" in
    "${PORTAL_GIT_BASE}"/*.git) rest="${1#"${PORTAL_GIT_BASE}"/}"; rest="${rest%.git}" ;;
    *) return 1 ;;
  esac
  [ -n "$rest" ] || return 1
  case "$rest" in *[!0-9]*) return 1 ;; esac
  return 0
}

# Mirror of the CLI's deriveRegistryName() (@sidebutton/server): strip scheme and
# .git, map / and : to -, drop the host when that leaves more than two segments,
# lowercase, keep [a-z0-9-]. Only a FALLBACK — the configured name is read from
# `sidebutton registry list` whenever the registry is actually configured, so a
# CLI-side change to the derivation (or an `--name` override) cannot strand us.
derive_registry_name() {
  local url="$1" stripped name path_part parts
  stripped="${url#https://}"; stripped="${stripped#http://}"; stripped="${stripped#git@}"
  stripped="${stripped%.git}"
  name="$(printf '%s' "$stripped" | tr '/:' '--')"
  parts="$(printf '%s' "$name" | tr '-' '\n' | grep -c .)"
  if [ "${parts:-0}" -gt 2 ]; then
    case "$stripped" in
      *:*) path_part="${stripped#*:}" ;;
      *)   path_part="${stripped#*/}" ;;
    esac
    if [ -n "$path_part" ] && [ "$path_part" != "$stripped" ]; then
      name="$(printf '%s' "$path_part" | tr '/' '-')"
    fi
  fi
  printf '%s' "$name" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-'
}

# ── configured registries (single cached `registry list` per run) ────────────
# The steady state must issue exactly the calls the pre-KAN-150 script did —
# one `registry list`, then `registry update` — so the list is read once and
# reused by the reconcile sweep, the add-if-missing guard and the name lookup.
# load_registry_list MUST be called from the top-level shell: every reader below
# runs in a subshell (a pipeline stage, `$(...)`, or a `< <(...)`), and a cache
# filled there would be thrown away with the subshell — which is exactly how the
# steady state ended up issuing two `registry list` calls instead of one.
REG_LIST_CACHE=""
REG_LIST_CACHED=0
load_registry_list() {
  REG_LIST_CACHE="$(sidebutton registry list 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g')"
  REG_LIST_CACHED=1
}
registry_list() {
  [ "$REG_LIST_CACHED" = 1 ] || load_registry_list
  printf '%s\n' "$REG_LIST_CACHE"
}

registry_configured() {  # is this url one of the configured registries?
  registry_list | grep -qF "$1"
}

configured_registries() {  # "<name>\t<url>" per configured GIT registry
  registry_list | awk '
    $2 == "(git)"                 { name = $1; next }
    $1 == "URL:" && name != ""    { print name "\t" $2; name = "" }
  '
}

configured_name_for() {  # <preferred-name> <url> -> the name that is really configured, or ""
  local want="$1" url="$2" n u
  while IFS=$'\t' read -r n u; do
    [ -n "${n:-}" ] || continue
    [ -n "$want" ] && [ "$n" = "$want" ] && { printf '%s' "$n"; return 0; }
    [ "${u:-}" = "$url" ] && { printf '%s' "$n"; return 0; }
  done < <(configured_registries)
  printf ''
}

registry_name_for_url() {  # configured name if we have one, else the derived name
  local name; name="$(configured_name_for "" "$1")"
  [ -n "$name" ] || name="$(derive_registry_name "$1")"
  printf '%s' "$name"
}

# ── the account-registry record ──────────────────────────────────────────────
REC_NAME=""
REC_URL=""
read_record() {
  REC_NAME=""; REC_URL=""
  [ -r "$RECORD_FILE" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      name) REC_NAME="$v" ;;
      url)  REC_URL="$v" ;;
    esac
  done < "$RECORD_FILE"
}

write_record() {  # write_record <name> <url>; silent + no-op when already current
  local name="$1" url="$2" desired tmp
  desired="$(printf 'name=%s\nurl=%s' "$name" "$url")"
  mkdir -p "$SB_DIR" 2>/dev/null || true
  if [ -r "$RECORD_FILE" ] && [ "$(cat "$RECORD_FILE" 2>/dev/null)" = "$desired" ]; then
    chmod 0600 "$RECORD_FILE" 2>/dev/null || true
    return 0
  fi
  tmp="${RECORD_FILE}.$$"
  if printf '%s\n' "$desired" > "$tmp" 2>/dev/null; then
    chmod 0600 "$tmp" 2>/dev/null || true
    if mv -f "$tmp" "$RECORD_FILE" 2>/dev/null; then
      log "account registry recorded: ${name} (${url})"
      return 0
    fi
  fi
  rm -f "$tmp" 2>/dev/null || true
  log "WARN: could not write ${RECORD_FILE} — switch detection falls back to the portal-host sweep" >&2
  return 1
}

# ── credentials ──────────────────────────────────────────────────────────────
# Scope the portal token to the portal git host, and only when a portal-hosted url
# is actually in play. GIT_CONFIG_* is the highest-precedence config source and is
# inherited by the git children `sidebutton registry add|update` spawns; the empty
# first value resets the inherited helper list FOR THAT HOST, then ours answers.
# The token is never written to git config or into a url — the helper reads it from
# the environment at call time, so a rotation is picked up with no re-auth.
export_registry_credential() {
  [ -n "${SIDEBUTTON_DEFAULT_REGISTRY_TOKEN:-}" ] || return 0
  local u host=""
  for u in "$@"; do
    [ -n "${u:-}" ] || continue
    if is_portal_url "$u"; then host="$(url_host "$u")"; break; fi
  done
  [ -n "$host" ] || return 0
  export SIDEBUTTON_DEFAULT_REGISTRY_TOKEN
  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0="credential.https://${host}.helper"
  export GIT_CONFIG_VALUE_0=""
  export GIT_CONFIG_KEY_1="credential.https://${host}.helper"
  export GIT_CONFIG_VALUE_1='!f(){ [ "$1" = get ] || exit 0; echo "username=x-access-token"; echo "password=${SIDEBUTTON_DEFAULT_REGISTRY_TOKEN}"; }; f'
  export GIT_TERMINAL_PROMPT=0
  log "portal registry token scoped to https://${host}"
}

# ── switch support ───────────────────────────────────────────────────────────
# `sidebutton registry remove` deletes the clone, so anything committed there and
# never pushed would be lost. Bundle it first and say where it went.
backup_unpushed_commits() {
  local name="$1" clone="${CLONES_DIR}/${1}" out
  [ -d "$clone/.git" ] || return 0
  [ -n "$(git -C "$clone" log --branches --not --remotes --format=%H 2>/dev/null | head -n1)" ] || return 0
  out="${SB_DIR}/registry-${name}-$(date -u +%Y%m%d-%H%M%S).bundle"
  if git -C "$clone" bundle create "$out" --all >/dev/null 2>&1; then
    log "unpushed commits in ${clone} — bundled to ${out}"
  else
    log "WARN: unpushed commits in ${clone} but 'git bundle create' failed — clone will be removed" >&2
  fi
}

case "$ACTION" in
  add)
    REGISTRY_URL="${2:-${SIDEBUTTON_DEFAULT_REGISTRY:-}}"
    if [ -z "$REGISTRY_URL" ]; then
      log "ERROR: no registry url (arg or \$SIDEBUTTON_DEFAULT_REGISTRY)" >&2
      exit 2
    fi
    export_registry_credential "$REGISTRY_URL"
    log "adding registry: ${REGISTRY_URL}"
    sidebutton registry add "$REGISTRY_URL"
    rc=$?
    # Record it whenever it IS configured afterwards — a fresh add, or a re-run
    # where the CLI refused because the registry already exists (that second case
    # is how a box provisioned before the record existed gets one, via base/19d
    # on the refresh path). A genuinely failed add records nothing.
    load_registry_list
    if registry_configured "$REGISTRY_URL"; then
      write_record "$(registry_name_for_url "$REGISTRY_URL")" "$REGISTRY_URL"
    fi
    exit "$rc"
    ;;
  record)
    REGISTRY_URL="${2:-${SIDEBUTTON_DEFAULT_REGISTRY:-}}"
    if [ -z "$REGISTRY_URL" ]; then
      log "ERROR: no registry url (arg or \$SIDEBUTTON_DEFAULT_REGISTRY)" >&2
      exit 2
    fi
    load_registry_list
    if ! registry_configured "$REGISTRY_URL"; then
      log "WARN: ${REGISTRY_URL} is not configured — nothing recorded" >&2
      exit 1
    fi
    write_record "$(registry_name_for_url "$REGISTRY_URL")" "$REGISTRY_URL"
    ;;
  update)
    NEW_URL="${SIDEBUTTON_DEFAULT_REGISTRY:-}"
    read_record

    # ── 1. reconcile a CHANGED account registry (remove-then-add) ────────────
    STALE_NAMES=()
    STALE_URLS=()
    stale_add() {  # <name> <url>, deduped by name
      local n
      for n in ${STALE_NAMES[@]+"${STALE_NAMES[@]}"}; do [ "$n" = "$1" ] && return 0; done
      STALE_NAMES+=("$1"); STALE_URLS+=("$2")
    }
    if [ -n "$NEW_URL" ]; then
      load_registry_list
      # a) the recorded account registry, when the delivered url has changed
      if [ -n "$REC_URL" ] && [ "$REC_URL" != "$NEW_URL" ]; then
        old_name="$(configured_name_for "$REC_NAME" "$REC_URL")"
        if [ -n "$old_name" ]; then
          stale_add "$old_name" "$REC_URL"
        else
          log "previously recorded registry ${REC_URL} is no longer configured — nothing to remove"
        fi
      fi
      # b) narrow fallback for boxes with no record (and for a record written
      #    after the switch already stacked the two): a configured registry with
      #    the portal's per-account shape that is not the delivered url.
      while IFS=$'\t' read -r rname rurl; do
        [ -n "${rurl:-}" ] || continue
        [ "$rurl" = "$NEW_URL" ] && continue
        is_portal_account_url "$rurl" && stale_add "$rname" "$rurl"
      done < <(configured_registries)
    fi

    SWITCHED_FROM=""
    if [ "${#STALE_NAMES[@]}" -gt 0 ]; then
      for i in "${!STALE_NAMES[@]}"; do
        log "account registry changed: ${STALE_URLS[$i]} -> ${NEW_URL} — removing ${STALE_NAMES[$i]}"
        backup_unpushed_commits "${STALE_NAMES[$i]}"
        if sidebutton registry remove "${STALE_NAMES[$i]}"; then
          log "removed previous registry ${STALE_NAMES[$i]} (its packs are uninstalled)"
          [ -n "$SWITCHED_FROM" ] || SWITCHED_FROM="${STALE_URLS[$i]}"
        else
          log "WARN: could not remove ${STALE_NAMES[$i]} — will retry next tick" >&2
        fi
      done
      load_registry_list
    fi

    # ── 2. add-if-missing (SCRUM-1167) ──────────────────────────────────────
    # The one-shot `add` in base/19d can fail transiently — the registry credential
    # (SIDEBUTTON_DEFAULT_REGISTRY_TOKEN, or the GH_TOKEN the gh helper uses for own-repo
    # accounts) lands in ~/.agent-env only after a later config-apply, so an add that ran
    # before the token arrived leaves the agent with NO registry. Historically this timer
    # only ran `update`, which pulls already-configured registries and therefore never
    # re-adds the missing one — so the account registry stayed absent forever.
    # Add-if-missing here heals that on the next tick, and re-adds after a switch above.
    if [ -n "$NEW_URL" ] && ! registry_configured "$NEW_URL"; then
      log "configured registry absent — reconciling (add ${NEW_URL})"
      export_registry_credential "$NEW_URL"
      sidebutton registry add "$NEW_URL" \
        || log "WARN: reconcile add failed — will retry next tick"
      load_registry_list
    fi

    # ── 3. record + switch log, once the new registry is really configured ───
    if [ -n "$NEW_URL" ] && { [ -n "$SWITCHED_FROM" ] || [ "$REC_URL" != "$NEW_URL" ]; } \
       && registry_configured "$NEW_URL"; then
      write_record "$(registry_name_for_url "$NEW_URL")" "$NEW_URL"
      [ -n "$SWITCHED_FROM" ] && log "registry switched ${SWITCHED_FROM} -> ${NEW_URL}"
    fi

    # ── 4. pull ─────────────────────────────────────────────────────────────
    # Scope the portal token for whatever is still configured: `registry update`
    # pulls every git registry, not just the account's.
    if [ -n "${SIDEBUTTON_DEFAULT_REGISTRY_TOKEN:-}" ]; then
      CRED_URLS=("$NEW_URL")
      while IFS=$'\t' read -r _n _u; do
        [ -n "${_u:-}" ] && CRED_URLS+=("$_u")
      done < <(configured_registries)
      export_registry_credential "${CRED_URLS[@]}"
    fi
    log "updating git registries (git pull)"
    sidebutton registry update
    ;;
  *)
    log "ERROR: unknown action '$ACTION' (expected add|record|update)" >&2
    exit 2
    ;;
esac
