#!/usr/bin/env bash
# base/tests/test-component-resolution.sh — guard for SCRUM-1447 (T4, AC2).
#
# Generalizes the per-component "silent-failure trap" the rdp/router tests each
# assert individually (a component dir + JSON entry that run.sh never sources =>
# it never installs, with no error). Holds for the WHOLE model:
#
#   * every base/components/<dir>     -> is a catalog slug (no orphan dirs) AND is
#                                        wired into run.sh (else it never runs);
#   * every catalog slug NOT base-installed -> has a base/components/<slug>/ dir;
#   * the base-installed slugs (chrome, sidebutton-server, knowledge-packs) are a
#     DOCUMENTED allowlist — each justified by the numbered base step that installs
#     it (06/08/13), not a component dir;
#   * every component dir ships >=1 lifecycle script + all *.sh parse (bash -n).
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-component-resolution.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
CATALOG="$ROOT/components.json"
RUN="$ROOT/base/run.sh"
COMP_DIR="$ROOT/base/components"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# Catalog slugs that ship NO component dir because a numbered base step installs
# them unconditionally-or-gated (verified: grep below). A future base-installed
# component must be added here or section 3 will (correctly) flag it.
#   chrome            -> base/06-chrome.sh        (gated on INSTALL_CHROME)
#   sidebutton-server -> base/08-sidebutton.sh    (gated on SKIP_SIDEBUTTON_SERVER)
#   knowledge-packs   -> base/13-knowledge-packs.sh (gated on SKIP_KNOWLEDGE_PACKS)
declare -A ALLOWLIST=(
  [chrome]="06-chrome.sh"
  [sidebutton-server]="08-sidebutton.sh"
  [knowledge-packs]="13-knowledge-packs.sh"
)

jq -e . "$CATALOG" >/dev/null 2>&1 && ok "components.json is valid JSON" \
  || { bad "components.json is not valid JSON"; echo "TEST FAILED"; exit 1; }

mapfile -t SLUGS < <(jq -r '.components[].slug' "$CATALOG")
is_slug() { local s; for s in "${SLUGS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# run.sh with full-comment lines stripped: a dir named only in a comment is NOT wired.
RUN_CODE="$(grep -vE '^[[:space:]]*#' "$RUN")"
# A dir is wired if its name appears as a whole slug token (delimited by anything
# other than [a-z0-9-]) — covers the dedicated includes (components/<dir>/...) and
# the `for _tc/_c in <dir> ...` loops, without matching a longer slug that contains
# it (e.g. `claude-code` must NOT be satisfied by `claude-code-router`).
is_wired() { printf '%s\n' "$RUN_CODE" | grep -Eq "(^|[^a-z0-9-])$1([^a-z0-9-]|\$)"; }

# ── 1. every component dir resolves to a slug AND is wired into run.sh ────────
for d in "$COMP_DIR"/*/; do
  dir="$(basename "$d")"
  if is_slug "$dir"; then ok "dir '$dir' resolves to a catalog slug"; else bad "dir '$dir' is an ORPHAN (no catalog slug)"; fi
  if is_wired "$dir"; then ok "run.sh wires '$dir' (sourced => it actually installs)"; else bad "run.sh NEVER sources '$dir' (silent-failure trap: dir+JSON but no wiring)"; fi
  if [ -f "$d/install.sh" ] || [ -f "$d/pre-services.sh" ] || [ -f "$d/post-services.sh" ]; then
    ok "dir '$dir' ships >=1 lifecycle script"
  else
    bad "dir '$dir' has no install.sh/pre-services.sh/post-services.sh"
  fi
done

# ── 2. every catalog slug NOT in the allowlist has a component dir ────────────
for s in "${SLUGS[@]}"; do
  if [ -n "${ALLOWLIST[$s]:-}" ]; then continue; fi
  [ -d "$COMP_DIR/$s" ] && ok "slug '$s' has base/components/$s/" \
    || bad "slug '$s' has no component dir and is not an allowlisted base-installed slug"
done

# ── 3. the allowlist is justified: no dir, but a real numbered base step installs it
for s in "${!ALLOWLIST[@]}"; do
  step="${ALLOWLIST[$s]}"
  [ ! -d "$COMP_DIR/$s" ] && ok "allowlisted '$s' has no component dir (base-installed)" \
    || bad "allowlisted '$s' unexpectedly has a component dir — drop it from the allowlist"
  [ -f "$ROOT/base/$step" ] && ok "allowlisted '$s' install step base/$step exists" \
    || bad "allowlisted '$s' references missing base step base/$step"
  grep -qF "$step" "$RUN" && ok "run.sh sources base/$step (installs '$s')" \
    || bad "run.sh does not source base/$step ('$s' would never install)"
done

# ── 4. every component shell script parses ───────────────────────────────────
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null && ok "bash -n: ${f#$ROOT/}" || bad "bash -n FAILED: ${f#$ROOT/}"
done < <(find "$COMP_DIR" -name '*.sh' | sort)

if [ "$fail" -ne 0 ]; then echo "TEST FAILED"; exit 1; fi
echo "All checks passed."
