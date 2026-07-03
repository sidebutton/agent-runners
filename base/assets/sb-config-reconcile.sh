#!/usr/bin/env bash
# sb-config-reconcile — apply the config files present at a component's default path
# (SCRUM-1599, A1). Triggered by sb-config-watch@<slug>.path (a systemd path unit) on
# any change, at boot (DirectoryNotEmpty/PathExists), and once by base/19f. It makes
# the component's live state MATCH the watched path:
#
#     sb-config-reconcile <slug>
#
# It reads the per-slug descriptor written by base/19f
# (/etc/sidebutton/components/<slug>.conf) and drives one of two modes:
#
#   mode=profile-dir  (wireguard, openvpn) — target_path is a directory of profiles.
#     For each accepted file: derive a tunnel name from the filename and apply it via
#     the component helper (`<helper> <file> <name>`), SHA-GATED so an unchanged file
#     never bounces a live tunnel. For each file this reconciler previously applied
#     whose backing file has vanished: tear it down (`<helper> remove <name>`).
#
#   mode=env-file  (rdp-client) — target_path is a single file. Present ⇒ enable+start
#     the service (re-read via try-restart on a SHA change); absent ⇒ disable it.
#
# OWNERSHIP: the reconciler only ever tears down what IT applied. Applied state is
# tracked in /etc/sidebutton/components/<slug>.applied (filename<TAB>name<TAB>sha), so
# a manually-created tunnel that collides with a watched filename is never removed by
# a de-scope. Idempotent + SHA-gated ⇒ safe to re-run from base/19f on every
# sb-self-update tick without bouncing a current tunnel.
set -uo pipefail

PROG="sb-config-reconcile"
STATE_DIR="${SB_COMPONENTS_DIR:-/etc/sidebutton/components}"

log() { printf '[%s] %s\n' "$PROG" "$*" >&2; logger -t "$PROG" -- "$*" 2>/dev/null || true; }
_sc() { if command -v systemctl >/dev/null 2>&1; then systemctl "$@" >/dev/null 2>&1 || return 1; else log "systemctl absent — skipped: $*"; return 0; fi; }

SLUG="${1:-}"
printf '%s' "$SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$' || { log "invalid/empty slug '${SLUG}'"; exit 2; }

DESC="${STATE_DIR}/${SLUG}.conf"
[ -f "$DESC" ] || { log "no descriptor at ${DESC} — nothing to reconcile for ${SLUG}"; exit 0; }
_get() { sed -n "s/^$1=//p" "$DESC" | tail -1; }
TARGET_PATH="$(_get target_path)"
ACCEPT="$(_get accept)"
MODE="$(_get mode)"
HELPER="$(_get helper)"
SERVICE="$(_get service)"
MANIFEST="${STATE_DIR}/${SLUG}.applied"
[ -n "$TARGET_PATH" ] || { log "descriptor ${DESC} has no target_path"; exit 1; }

# filename → safe tunnel/instance name: strip the accepted suffix, map anything outside
# [A-Za-z0-9_.-] to '_', cap at 15 chars (wg-quick's interface-name limit; safe for
# openvpn-client@ too).
_derive_name() {
  local fname="$1" base="$1" suf
  for suf in $ACCEPT; do case "$fname" in *"$suf") base="${fname%"$suf"}"; break ;; esac; done
  printf '%s' "$base" | LC_ALL=C tr -c 'A-Za-z0-9_.-' '_' | cut -c1-15
}
_sha() { sha256sum -- "$1" 2>/dev/null | awk '{print $1}'; }
_manifest_sha()  { [ -f "$MANIFEST" ] && awk -F'\t' -v k="$1" '$1==k{print $3; exit}' "$MANIFEST" 2>/dev/null; }

reconcile_profile_dir() {
  local dir="${TARGET_PATH%/}"
  [ -n "$HELPER" ] && [ -x "$HELPER" ] || { log "helper '${HELPER}' missing/not executable — skipping ${SLUG}"; return 0; }
  mkdir -p -- "$dir" 2>/dev/null || true

  local tmp; tmp="$(mktemp)" || { log "mktemp failed"; return 1; }
  declare -A seen=()
  local f fname name sha prev
  shopt -s nullglob
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && { log "ignoring symlink in ${dir}: $(basename -- "$f")"; continue; }
    fname="$(basename -- "$f")"
    case "$fname" in *$'\t'*|*$'\n'*) log "ignoring odd filename in ${dir}"; continue ;; esac
    # accept-suffix filter (when the component declares any)
    if [ -n "$ACCEPT" ]; then
      local ok=0 suf
      for suf in $ACCEPT; do case "$fname" in *"$suf") ok=1; break ;; esac; done
      [ "$ok" -eq 1 ] || continue
    fi
    name="$(_derive_name "$fname")"
    [ -n "$name" ] || { log "cannot derive a valid name from '${fname}' — skipped"; continue; }
    sha="$(_sha "$f")"
    prev="$(_manifest_sha "$fname")"
    if [ "$sha" != "$prev" ]; then
      log "applying ${SLUG} profile '${fname}' as '${name}'"
      if "$HELPER" "$f" "$name" >/dev/null 2>&1; then
        log "applied '${fname}' → ${name}"
      else
        log "WARN: helper failed for '${fname}' (${name}) — will retry next change"
      fi
    fi
    printf '%s\t%s\t%s\n' "$fname" "$name" "$sha" >> "$tmp"
    seen["$fname"]=1
  done
  shopt -u nullglob

  # Tear down profiles this reconciler applied whose backing file has vanished.
  if [ -f "$MANIFEST" ]; then
    local mf mn ms
    while IFS=$'\t' read -r mf mn ms; do
      [ -n "${mf:-}" ] || continue
      if [ -z "${seen[$mf]:-}" ]; then
        log "de-scoping ${SLUG} '${mf}' (${mn}) — backing file gone, tearing down"
        "$HELPER" remove "$mn" >/dev/null 2>&1 || log "WARN: teardown failed for ${mn}"
      fi
    done < "$MANIFEST"
  fi

  mv -f -- "$tmp" "$MANIFEST" 2>/dev/null || { log "could not update manifest ${MANIFEST}"; rm -f -- "$tmp"; return 1; }
  chmod 600 -- "$MANIFEST" 2>/dev/null || true
}

reconcile_env_file() {
  [ -n "$SERVICE" ] || { log "env-file mode for ${SLUG} has no service — nothing to do"; return 0; }
  local file="$TARGET_PATH" sha prev
  if [ -f "$file" ]; then
    sha="$(_sha "$file")"
    prev="$([ -f "$MANIFEST" ] && awk -F'\t' 'NR==1{print $3}' "$MANIFEST" 2>/dev/null)"
    _sc enable "$SERVICE"
    _sc start  "$SERVICE"
    if [ -n "${prev:-}" ] && [ "$sha" != "$prev" ]; then
      log "${file} changed — re-reading via try-restart ${SERVICE}"
      _sc try-restart "$SERVICE"
    else
      log "${SERVICE} ensured enabled+running for ${file}"
    fi
    printf 'env\t%s\t%s\n' "$SERVICE" "$sha" > "$MANIFEST" 2>/dev/null || log "could not write manifest ${MANIFEST}"
    chmod 600 -- "$MANIFEST" 2>/dev/null || true
  else
    if [ -f "$MANIFEST" ]; then
      log "${file} removed — disabling ${SERVICE}"
      _sc disable "$SERVICE"
      _sc stop    "$SERVICE"
      rm -f -- "$MANIFEST" 2>/dev/null || true
    else
      log "${file} absent and nothing applied — no-op"
    fi
  fi
}

case "$MODE" in
  profile-dir) reconcile_profile_dir ;;
  env-file)    reconcile_env_file ;;
  *)           log "unknown mode '${MODE}' in ${DESC} — nothing to do"; exit 1 ;;
esac
