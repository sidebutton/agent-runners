#!/usr/bin/env bash
# sb-config-place — the ONE privileged hop for component config-file delivery
# (SCRUM-1599, A1). Installed to /usr/local/bin/sb-config-place by base/19f and run
# as root via a narrow NOPASSWD sudoers rule scoped to ONLY this wrapper. The agent
# server (non-root) stages a file under its own dir, then asks this wrapper to
# install it into the component's declared target path root:600.
#
#     sudo sb-config-place <slug> <staged-file> [filename]   # place / replace
#     sudo sb-config-place --remove <slug> [filename]        # de-scope (reconcile)
#
# THIS WRAPPER IS THE WHOLE TRUST BOUNDARY. sudoers cannot constrain argv, so every
# argument is validated here before any privileged write:
#   * <slug> must be an installed config-declaring component (its descriptor,
#     /etc/sidebutton/components/<slug>.conf, is written by base/19f only).
#   * the destination is confined to the component's declared target_path — a single
#     safe path segment (no '/', no '..', no leading '-', no NUL), realpath-resolved
#     so it cannot escape the declared directory, and never a symlink.
#   * the staged source must be a real (non-symlink) readable file.
# Path/argument validation happens BEFORE the root check so the security-critical
# rejections are unit-testable without privilege; the actual mutation is root-only.
#
# Descriptor format (KEY=value, root:600, written by base/19f):
#   slug=wireguard
#   target_path=/etc/sidebutton/config/wireguard/    # trailing '/' ⇒ directory (many files)
#   multiple=true                                    # no slash ⇒ single pinned file
#   accept=.conf                                     # space-separated suffixes ('' ⇒ any)
set -euo pipefail

PROG="sb-config-place"
# Overridable only so the traversal/confinement guards are testable off a real box;
# defaults to the real location. NOT a security knob — descriptors are root-owned.
COMPONENTS_DIR="${SB_COMPONENTS_DIR:-/etc/sidebutton/components}"

die()  { echo "${PROG}: $*" >&2; exit 1; }
usage() {
  echo "usage: sudo ${PROG} <slug> <staged-file> [filename]" >&2
  echo "       sudo ${PROG} --remove <slug> [filename]" >&2
  exit 2
}

# ── parse args ────────────────────────────────────────────────────────────────
REMOVE=0
if [ "${1:-}" = "--remove" ]; then REMOVE=1; shift; fi

SLUG="${1:-}"; [ -n "$SLUG" ] || usage
if [ "$REMOVE" -eq 1 ]; then
  STAGED=""
  FILENAME="${2:-}"
else
  STAGED="${2:-}"; [ -n "$STAGED" ] || usage
  FILENAME="${3:-}"
fi

# ── validate slug + load its descriptor ───────────────────────────────────────
printf '%s' "$SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$' \
  || die "invalid slug '${SLUG}' (expected ^[a-z0-9][a-z0-9-]*\$)"

DESC="${COMPONENTS_DIR}/${SLUG}.conf"
[ -f "$DESC" ] && [ ! -L "$DESC" ] \
  || die "unknown/uninstalled component '${SLUG}' (no descriptor at ${DESC})"

# Parse the descriptor by grep (never source it) — take the LAST value per key.
_desc_get() { sed -n "s/^$1=//p" "$DESC" | tail -1; }
TARGET_PATH="$(_desc_get target_path)"
ACCEPT="$(_desc_get accept)"
[ -n "$TARGET_PATH" ] || die "descriptor ${DESC} has no target_path"
case "$TARGET_PATH" in
  /*) : ;;                       # must be absolute
  *)  die "descriptor target_path '${TARGET_PATH}' is not absolute" ;;
esac

# Directory target (trailing '/') accepts a named filename; file target pins one.
case "$TARGET_PATH" in
  */) IS_DIR=1; DEST_DIR="${TARGET_PATH%/}"; PINNED="" ;;
  *)  IS_DIR=0; DEST_DIR="$(dirname -- "$TARGET_PATH")"; PINNED="$(basename -- "$TARGET_PATH")" ;;
esac

# ── resolve + validate the destination filename ───────────────────────────────
valid_segment() {  # single safe path segment, no traversal, no option-looking lead
  local n="$1"
  [ -n "$n" ]                                  || return 1
  case "$n" in */*|.|..|-*) return 1 ;; esac   # no slash, no . / .., no leading '-'
  printf '%s' "$n" | LC_ALL=C grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

if [ "$IS_DIR" -eq 1 ]; then
  # Default the name from the staged file (place form); required for --remove.
  if [ -z "$FILENAME" ]; then
    [ "$REMOVE" -eq 1 ] && die "--remove needs a filename for directory target ${TARGET_PATH}"
    FILENAME="$(basename -- "$STAGED")"
  fi
  valid_segment "$FILENAME" || die "invalid filename '${FILENAME}' (one safe segment: [A-Za-z0-9._-], no '/' or '..')"
else
  # Single-file target: the filename is pinned by the declaration.
  if [ -n "$FILENAME" ] && [ "$FILENAME" != "$PINNED" ]; then
    die "component '${SLUG}' pins a single file '${PINNED}' — refusing filename '${FILENAME}'"
  fi
  FILENAME="$PINNED"
  valid_segment "$FILENAME" || die "descriptor pins an unsafe filename '${FILENAME}'"
fi

# Enforce the declared accept[] suffixes (when any are declared).
if [ -n "$ACCEPT" ]; then
  _match=0
  for _suf in $ACCEPT; do
    case "$FILENAME" in *"$_suf") _match=1; break ;; esac
  done
  [ "$_match" -eq 1 ] || die "filename '${FILENAME}' does not match accepted suffixes: ${ACCEPT}"
fi

# Confinement: with FILENAME already a single safe segment, the canonical DEST must
# equal <canonical declared dir>/<filename> exactly. realpath -m resolves any '..' or
# symlinked component of the declared dir without requiring the path to exist yet, so
# a DEST that resolved anywhere else (e.g. via a symlinked target dir) is rejected.
DEST="${DEST_DIR}/${FILENAME}"
REAL_ALLOWED="$(realpath -m -- "$DEST_DIR")"
REAL_DEST="$(realpath -m -- "$DEST")"
[ "$REAL_DEST" = "${REAL_ALLOWED}/${FILENAME}" ] \
  || die "resolved destination '${REAL_DEST}' escapes declared root '${REAL_ALLOWED}'"
# Never write THROUGH a planted symlink at the destination.
[ -L "$DEST" ] && die "destination '${DEST}' is a symlink — refusing to write through it"

# ── privilege boundary: everything past here mutates root-owned state ──────────
[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

if [ "$REMOVE" -eq 1 ]; then
  if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    rm -f -- "$DEST" && echo "${PROG}: removed ${DEST}"
  else
    echo "${PROG}: nothing to remove at ${DEST}"
  fi
  exit 0
fi

# Place form: the staged source must be a real, readable, regular file (not a
# symlink — the agent server stages real files; a symlink would let a caller read an
# arbitrary root-readable file into a predictable place).
[ -n "$STAGED" ]  || usage
[ ! -L "$STAGED" ] || die "staged source '${STAGED}' is a symlink — refusing"
[ -f "$STAGED" ]  || die "staged source '${STAGED}' is not a regular file"
[ -r "$STAGED" ]  || die "staged source '${STAGED}' is not readable"

install -D -m 600 -o root -g root -- "$STAGED" "$DEST"
echo "${PROG}: installed ${DEST} (root:600)"
