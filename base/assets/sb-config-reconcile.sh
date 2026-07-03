#!/usr/bin/env bash
# sb-config-reconcile <slug> — apply the config files present at a component's
# declared target_path, and tear down what it previously applied but is now gone
# (SCRUM-1599 / epic SCRUM-1597).
#
# Run as root by sb-config-apply@<slug>.service (triggered by the per-slug path-unit
# watcher on new/changed/removed files), by base/19f once at provision for boot-time
# apply, and by hand for debugging. It reads the same descriptor sb-config-place
# validates against (/etc/sidebutton/components/<slug>.conf) so on-disk placement —
# manual SSH or portal push — converges on identical behaviour (D3). The manual
# sb-*-connect helpers stay break-glass.
#
# Two consumption styles (descriptor `consume=`):
#   helper  — a DIRECTORY of named configs. Each file <name><suffix> is applied via
#             `<helper_bin> <file> <name>` (e.g. sb-wg-connect → wg-quick@<name>);
#             a file that vanished is torn down via `<helper_bin> remove <name>`.
#             Applies are sha-gated against a state file OUTSIDE the watched dir, so a
#             routine re-run (sb-self-update / extra watcher tick) never bounces a live
#             tunnel, and teardown only ever touches names THIS reconcile brought up —
#             a manually-created same-named tunnel is never in the state, so never cut.
#   service — a SINGLE pinned file (e.g. /etc/sidebutton/rdp.env). Present ⇒ enable
#             + start the service (the idle-waiting helper then consumes the file —
#             "zero consumption change"); absent ⇒ disable + stop it.
set -uo pipefail    # NOT -e: one bad file must not abort the whole reconcile

SLUG="${1:?usage: sb-config-reconcile <slug>}"
printf '%s' "$SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$' || { echo "invalid slug '$SLUG'" >&2; exit 1; }

COMP_DIR="${SB_COMPONENTS_DIR:-/etc/sidebutton/components}"
RUN_DIR="${SB_CONFIG_RUN_DIR:-/run}"
DESC="${COMP_DIR}/${SLUG}.conf"
[ -r "$DESC" ] || { echo "no descriptor for '$SLUG' (${DESC})" >&2; exit 1; }

_desc() { sed -n "s/^$1=//p" "$DESC" | tail -1; }
TARGET_PATH="$(_desc target_path)"
ACCEPT="$(_desc accept)"
CONSUME="$(_desc consume)"
HELPER_BIN="$(_desc helper_bin)"
SERVICE="$(_desc service)"
NAME_MAX="$(_desc name_max)"
[ -n "$TARGET_PATH" ] || { echo "descriptor for '$SLUG' has no target_path" >&2; exit 1; }

log() { printf '[sb-config-reconcile:%s] %s\n' "$SLUG" "$*"; }

# Serialise reconciles for this slug so a watcher tick and the boot apply (or two
# rapid file drops) never run sb-*-connect on the same tunnel concurrently.
mkdir -p "$RUN_DIR" 2>/dev/null || true
LOCK="${RUN_DIR}/sb-config-reconcile.${SLUG}.lock"
exec 9>"$LOCK" 2>/dev/null || true
flock -w 60 9 2>/dev/null || true

# ── service style: presence of the single file gates the service ─────────────
if [ "$CONSUME" = "service" ]; then
  [ -n "$SERVICE" ] || { echo "descriptor for '$SLUG' has consume=service but no service" >&2; exit 1; }
  if [ -e "$TARGET_PATH" ]; then
    systemctl enable --now "$SERVICE" >/dev/null 2>&1 && log "present ⇒ ${SERVICE} enabled+started" \
      || log "WARN: could not enable ${SERVICE}"
  else
    systemctl disable --now "$SERVICE" >/dev/null 2>&1 && log "absent ⇒ ${SERVICE} disabled" \
      || log "absent ⇒ ${SERVICE} not running"
  fi
  exit 0
fi

# ── helper style: reconcile a directory of named configs ─────────────────────
[ "$CONSUME" = "helper" ] || { echo "descriptor for '$SLUG' has unknown consume='${CONSUME}'" >&2; exit 1; }
[ -x "$HELPER_BIN" ] || { echo "helper ${HELPER_BIN} not installed for '$SLUG'" >&2; exit 1; }
WATCH_DIR="${TARGET_PATH%/}"
STATE="${COMP_DIR}/${SLUG}.applied"    # name<TAB>sha, one per line — OUTSIDE WATCH_DIR

# _stem <basename> — strip the first matching accept suffix, else return as-is.
_stem() {
  local b="$1" ext
  for ext in $(printf '%s' "$ACCEPT" | tr ',' ' '); do
    case "$b" in *"$ext") printf '%s' "${b%"$ext"}"; return 0 ;; esac
  done
  printf '%s' "$b"
}

# Desired set: name -> file, from the regular files currently in the watch dir.
declare -A WANT_FILE=()
if [ -d "$WATCH_DIR" ]; then
  shopt -s nullglob
  for f in "$WATCH_DIR"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    base="$(basename -- "$f")"
    case "$base" in .*) continue ;; esac          # skip dotfiles
    name="$(_stem "$base")"
    [ -n "$NAME_MAX" ] && name="${name:0:$NAME_MAX}"   # e.g. wg iface ≤15 chars
    [ -n "$name" ] || continue
    if [ -n "${WANT_FILE[$name]:-}" ]; then
      log "WARN: '${base}' collides with an earlier file on name '${name}' — skipping"
      continue
    fi
    WANT_FILE[$name]="$f"
  done
  shopt -u nullglob
fi

# Previous state: name -> sha.
declare -A PREV_SHA=()
if [ -r "$STATE" ]; then
  while IFS=$'\t' read -r pn psha; do
    [ -n "$pn" ] && PREV_SHA[$pn]="$psha"
  done < "$STATE"
fi

_sha() { sha256sum -- "$1" 2>/dev/null | awk '{print $1}'; }

# Apply new/changed files (sha-gated so unchanged tunnels are never bounced).
declare -A NEW_SHA=()
for name in "${!WANT_FILE[@]}"; do
  f="${WANT_FILE[$name]}"
  sha="$(_sha "$f")"
  if [ "${PREV_SHA[$name]:-}" = "$sha" ] && [ -n "$sha" ]; then
    NEW_SHA[$name]="$sha"                          # unchanged — leave the live tunnel alone
    continue
  fi
  log "applying '${name}' from $(basename -- "$f")"
  if "$HELPER_BIN" "$f" "$name" >/dev/null 2>&1; then
    NEW_SHA[$name]="$sha"
    log "applied '${name}'"
  else
    log "WARN: ${HELPER_BIN} failed for '${name}' (see journalctl) — will retry next tick"
  fi
done

# Tear down anything previously applied whose file is gone now.
for name in "${!PREV_SHA[@]}"; do
  if [ -z "${WANT_FILE[$name]:-}" ]; then
    log "tearing down '${name}' (file removed)"
    "$HELPER_BIN" remove "$name" >/dev/null 2>&1 || log "WARN: teardown of '${name}' reported an error"
  fi
done

# Persist the new state (only successfully-tracked names). Written atomically to a
# temp beside STATE (never inside WATCH_DIR, which would re-trigger the watcher).
tmp="${STATE}.tmp.$$"
: > "$tmp"
for name in "${!NEW_SHA[@]}"; do printf '%s\t%s\n' "$name" "${NEW_SHA[$name]}" >> "$tmp"; done
mv -f "$tmp" "$STATE" 2>/dev/null || rm -f "$tmp"
chmod 600 "$STATE" 2>/dev/null || true
log "reconcile done (${#NEW_SHA[@]} applied, $(( ${#PREV_SHA[@]} - ${#NEW_SHA[@]} > 0 ? ${#PREV_SHA[@]} - ${#NEW_SHA[@]} : 0 )) torn down)"
exit 0
