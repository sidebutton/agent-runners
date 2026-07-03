#!/usr/bin/env bash
# sb-config-place — the ONE privileged hop that lands a component config file at
# its declared default path (SCRUM-1599 / epic SCRUM-1597).
#
#   sudo sb-config-place <slug> <staged-file> [filename]   # install root:600
#   sudo sb-config-place --remove <slug> [filename]        # delete (reconcile tears down)
#
# Installed to /usr/local/bin/sb-config-place by base/19f and run as root via a
# NARROW NOPASSWD sudoers rule scoped to ONLY this wrapper (same pattern as
# sb-self-update). The agent server (non-root) stages an uploaded profile under its
# own dir, then calls this to place it where the component's watcher consumes it.
#
# THIS WRAPPER IS THE ENTIRE TRUST BOUNDARY: sudoers cannot constrain arguments, so
# every check that keeps this from becoming an arbitrary-write-as-root primitive
# lives here. It only ever writes INSIDE the target_path a component DECLARED in its
# catalog entry (mirrored to /etc/sidebutton/components/<slug>.conf by 19f):
#   - the slug must resolve to an installed component's descriptor;
#   - the filename must be a single safe segment (no /, no '..', no leading dot/dash,
#     no symlink), realpath-confined to the declared dir;
#   - a single-file component (e.g. rdp.env) pins its exact basename.
#
# Validation is read-only and runs BEFORE the root gate + the install/rm, so the
# rejection paths are unit-testable without root (base/tests/test-component-config.sh)
# and NOTHING is mutated until every check has passed. SB_COMPONENTS_DIR overrides the
# descriptor dir for those tests; sudo's env_reset strips it in production, so the
# fleet always reads /etc/sidebutton/components.
set -euo pipefail

COMP_DIR="${SB_COMPONENTS_DIR:-/etc/sidebutton/components}"

usage() {
  echo "usage: sudo sb-config-place <slug> <staged-file> [filename]" >&2
  echo "       sudo sb-config-place --remove <slug> [filename]" >&2
  exit 2
}

die() { echo "sb-config-place: $*" >&2; exit 1; }

# ── parse mode + args ────────────────────────────────────────────────────────
MODE="place"
if [ "${1:-}" = "--remove" ]; then MODE="remove"; shift; fi

SLUG="${1:-}"
[ -n "$SLUG" ] || usage
if [ "$MODE" = "place" ]; then
  STAGED="${2:-}"; [ -n "$STAGED" ] || usage
  FILENAME_ARG="${3:-}"
else
  FILENAME_ARG="${2:-}"
fi

# ── validate slug (strict; no path chars) + resolve its declaration ──────────
# Whole-string bash regex, NOT `grep -qE`: grep is line-oriented, so an embedded
# newline splits the value and a single conforming line would pass — [[ =~ ]]
# anchors ^/$ to the whole string and rejects any control char.
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
  || die "invalid slug '$SLUG' (must match ^[a-z0-9][a-z0-9-]*\$)"

DESC="${COMP_DIR}/${SLUG}.conf"
[ -f "$DESC" ] && [ ! -L "$DESC" ] && [ -r "$DESC" ] \
  || die "component '$SLUG' is not installed or declares no config file (${DESC} absent)"

# Descriptor is root-written KEY=VALUE; read specific keys (never sourced).
_desc() { sed -n "s/^$1=//p" "$DESC" | tail -1; }
TARGET_PATH="$(_desc target_path)"
MULTIPLE="$(_desc multiple)"
ACCEPT="$(_desc accept)"
[ -n "$TARGET_PATH" ] || die "descriptor for '$SLUG' has no target_path"

# ── directory (multi) vs single-file target ──────────────────────────────────
case "$TARGET_PATH" in
  */) IS_DIR=1 ;;
  *)  [ "$MULTIPLE" = "1" ] && IS_DIR=1 || IS_DIR=0 ;;
esac

# _accept_ok <filename> — true unless an accept[] list is declared and the name
# matches none of the suffixes (defence in depth; the portal filters too).
_accept_ok() {
  [ -n "$ACCEPT" ] || return 0
  local fn="$1" ext
  for ext in $(printf '%s' "$ACCEPT" | tr ',' ' '); do
    case "$fn" in *"$ext") return 0 ;; esac
  done
  return 1
}

if [ "$IS_DIR" = "1" ]; then
  TARGET_DIR="${TARGET_PATH%/}"
  [ -d "$TARGET_DIR" ] && [ ! -L "$TARGET_DIR" ] || die "target dir ${TARGET_DIR} missing (component not wired)"
  RP_DIR="$(realpath -- "$TARGET_DIR")" || die "cannot resolve ${TARGET_DIR}"

  # filename: explicit arg, else the staged file's basename (place only).
  FN="$FILENAME_ARG"
  if [ -z "$FN" ]; then
    [ "$MODE" = "place" ] || die "--remove on a directory target needs a filename"
    FN="$(basename -- "$STAGED")"
  fi
  # single safe segment — no '/', no '..', no leading dot/dash, printable set only.
  # Whole-string bash regex, NOT `grep -qE`: grep matches per line, so a newline in
  # the name would let a conforming first line pass while an arbitrary tail rides
  # through (and would then corrupt the TAB/newline-delimited reconcile state file).
  # [[ =~ ]] anchors to the whole string and rejects any control char / newline.
  [[ "$FN" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "unsafe filename '$FN' (single safe segment only)"
  case "$FN" in *..*|*/*) die "unsafe filename '$FN' (path traversal)";; esac
  _accept_ok "$FN" || die "filename '$FN' does not match accepted suffix(es) ($ACCEPT)"

  DEST="${RP_DIR}/${FN}"
  # Confinement: the resolved parent of DEST must be EXACTLY the declared dir.
  RP_PARENT="$(realpath -m -- "$(dirname -- "$DEST")")"
  [ "$RP_PARENT" = "$RP_DIR" ] || die "target '$DEST' escapes ${RP_DIR}"
else
  # Single pinned file (e.g. /etc/sidebutton/rdp.env): the basename is fixed.
  BASENAME="$(basename -- "$TARGET_PATH")"
  if [ -n "$FILENAME_ARG" ] && [ "$FILENAME_ARG" != "$BASENAME" ]; then
    die "component '$SLUG' pins a single file (${BASENAME}); '$FILENAME_ARG' not allowed"
  fi
  RP_PARENT="$(realpath -m -- "$(dirname -- "$TARGET_PATH")")"
  [ -d "$RP_PARENT" ] || die "parent dir of ${TARGET_PATH} missing"
  _accept_ok "$BASENAME" || die "pinned file '$BASENAME' does not match accepted suffix(es) ($ACCEPT)"
  DEST="${RP_PARENT}/${BASENAME}"
fi

# Never write through / delete through an existing symlink at DEST.
[ -L "$DEST" ] && die "refusing to act on a symlink at ${DEST}"

# ── privileged mutation (root only, AFTER every read-only check) ─────────────
[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

if [ "$MODE" = "place" ]; then
  [ -f "$STAGED" ] && [ ! -L "$STAGED" ] || die "no such staged regular file: ${STAGED}"
  install -m 600 -o root -g root -- "$STAGED" "$DEST"
  echo "placed: ${DEST} (root:600)"
else
  rm -f -- "$DEST"
  echo "removed: ${DEST}"
fi
