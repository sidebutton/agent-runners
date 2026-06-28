#!/usr/bin/env bash
# base/tests/test-components-schema.sh — guard for SCRUM-1447 (T4, AC1).
#
# Validates components.json AGAINST components.schema.json (the README promises
# "components.json is validated against components.schema.json" — until now that
# was aspirational; nothing enforced it). Plus the two SEMANTIC rules a JSON-Schema
# draft cannot express: slugs are unique, and every `requires[]` target is itself a
# catalog slug.
#
# The constraints are READ FROM THE SCHEMA at runtime (required keys, allowed keys,
# slug pattern, the kind/unlocks/processKey/versionKey enums) rather than hard-coded,
# so this validator tracks schema edits instead of silently drifting from them. It is
# a jq STRUCTURAL validator, deliberately NOT ajv-cli/npx: every guard in this suite
# declares "no bats/CI dependency", jq is already assumed present, and it runs offline.
#
# Schema -> check map (components.schema.json):
#   root.required L7, version L10, components/minItems L13   -> sections 2-4
#   $defs.component.required L20                              -> section 5
#   $defs.component additionalProperties:false L57           -> section 6
#   $defs.component.properties.slug.pattern L24              -> section 7
#   $defs.component.properties.kind.enum L29                 -> section 8
#   requires items:string L35-36                             -> section 9
#   $defs.component.properties.unlocks.items.enum L41        -> section 10
#   $defs...chip.required L48 / addlProps:false L54          -> sections 11-12
#   chip.processKey/versionKey enums L51-52                  -> sections 13-14
#   (root has NO additionalProperties:false — extra top-level keys like $schema are
#    permitted by the schema, so this validator does NOT reject them. See section 1b.)
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-components-schema.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
CATALOG="$ROOT/components.json"
SCHEMA="$ROOT/components.schema.json"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }
# Assert a jq query over the catalog yields NO offending rows. Everything after the
# message is forwarded to jq verbatim (its --arg/--argjson options + the filter); the
# catalog path is appended. A non-empty result => violations, listed in the failure.
none() { # <message> <jq-args... filter>
  local msg="$1"; shift
  local out; out="$(jq -r "$@" "$CATALOG" 2>&1)"
  if [ -z "$out" ]; then ok "$msg"; else bad "$msg -> $(printf '%s' "$out" | paste -sd'; ' -)"; fi
}

# ── 1. both documents are valid JSON ─────────────────────────────────────────
jq -e . "$CATALOG" >/dev/null 2>&1 && ok "components.json is valid JSON" || { bad "components.json is not valid JSON"; echo "TEST FAILED"; exit 1; }
jq -e . "$SCHEMA"  >/dev/null 2>&1 && ok "components.schema.json is valid JSON" || { bad "components.schema.json is not valid JSON"; echo "TEST FAILED"; exit 1; }

# Pull the constraints out of the schema so the checks track it.
COMP_REQ="$(jq -c '.["$defs"].component.required' "$SCHEMA")"
COMP_ALLOWED="$(jq -c '[.["$defs"].component.properties|keys[]]' "$SCHEMA")"
SLUG_PAT="$(jq -r '.["$defs"].component.properties.slug.pattern' "$SCHEMA")"
KIND_ENUM="$(jq -c '.["$defs"].component.properties.kind.enum' "$SCHEMA")"
UNLOCKS_ENUM="$(jq -c '.["$defs"].component.properties.unlocks.items.enum' "$SCHEMA")"
CHIP_REQ="$(jq -c '.["$defs"].component.properties.chip.required' "$SCHEMA")"
CHIP_ALLOWED="$(jq -c '[.["$defs"].component.properties.chip.properties|keys[]]' "$SCHEMA")"
PK_ENUM="$(jq -c '.["$defs"].component.properties.chip.properties.processKey.enum' "$SCHEMA")"
VK_ENUM="$(jq -c '.["$defs"].component.properties.chip.properties.versionKey.enum' "$SCHEMA")"

# ── 1b. validator-fidelity guards: the schema must still declare what we encode ─
jq -e '.["$defs"].component.additionalProperties==false' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema pins component.additionalProperties:false (validator assumption holds)" \
  || bad "schema no longer pins component.additionalProperties:false — update this validator"
jq -e '.["$defs"].component.properties.chip.additionalProperties==false' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema pins chip.additionalProperties:false (validator assumption holds)" \
  || bad "schema no longer pins chip.additionalProperties:false — update this validator"
jq -e 'has("additionalProperties")|not' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema root permits extra top-level keys (so \$schema is allowed; not enforced here)" \
  || bad "schema root now constrains additionalProperties — this validator must enforce it too"

# ── 2-4. top level ───────────────────────────────────────────────────────────
jq -e 'has("version") and has("components")' "$CATALOG" >/dev/null 2>&1 \
  && ok "top-level has version + components (schema required)" || bad "missing version/components"
jq -e '.version|(type=="number" and .>=1 and (.==floor))' "$CATALOG" >/dev/null 2>&1 \
  && ok "version is an integer >= 1" || bad "version is not an integer >= 1"
jq -e '.components|(type=="array" and length>=1)' "$CATALOG" >/dev/null 2>&1 \
  && ok "components is a non-empty array (minItems 1)" || bad "components is not a non-empty array"

# ── 5. each component carries the schema-required keys ───────────────────────
none "every component has the required keys $(printf '%s' "$COMP_REQ" | jq -r 'join(",")')" \
  --argjson req "$COMP_REQ" \
  '.components[] | . as $c | ($req-($c|keys)) as $m | select($m|length>0) | "\($c.slug // "?"): missing \($m|join(","))"'

# ── 6. additionalProperties:false at the component level ─────────────────────
none "no unknown keys on any component (additionalProperties:false)" \
  --argjson ok "$COMP_ALLOWED" \
  '.components[] | . as $c | (($c|keys)-$ok) as $x | select($x|length>0) | "\($c.slug): unknown \($x|join(","))"'

# ── 7. slug pattern ──────────────────────────────────────────────────────────
none "every slug matches $SLUG_PAT" \
  --arg pat "$SLUG_PAT" \
  '.components[] | select((.slug|type)!="string" or (.slug|test($pat)|not)) | "\(.slug|tostring) fails slug pattern"'

# ── 8. kind enum ─────────────────────────────────────────────────────────────
none "every kind in $KIND_ENUM" \
  --argjson e "$KIND_ENUM" \
  '.components[] | select((.kind) as $k | ($e|index($k))|not) | "\(.slug): kind=\(.kind|tostring)"'

# ── 9. requires is an array of strings ───────────────────────────────────────
none "every requires is an array of strings" \
  '.components[] | select((.requires|type)!="array" or ([.requires[]?|select(type!="string")]|length>0)) | "\(.slug): bad requires"'

# ── 10. unlocks enum (when present) ──────────────────────────────────────────
none "every unlocks[] in $UNLOCKS_ENUM" \
  --argjson e "$UNLOCKS_ENUM" \
  '.components[] | select(has("unlocks")) | . as $c | [.unlocks[] as $u | select(($e|index($u))|not) | $u] as $b | select($b|length>0) | "\($c.slug): unlocks \($b|join(","))"'

# ── 11. chip.required (when chip present) ────────────────────────────────────
none "every chip has the required keys $(printf '%s' "$CHIP_REQ" | jq -r 'join(",")')" \
  --argjson req "$CHIP_REQ" \
  '.components[] | select(has("chip")) | . as $c | ($req-($c.chip|keys)) as $m | select($m|length>0) | "\($c.slug): chip missing \($m|join(","))"'

# ── 12. chip additionalProperties:false ──────────────────────────────────────
none "no unknown keys on any chip (additionalProperties:false)" \
  --argjson ok "$CHIP_ALLOWED" \
  '.components[] | select(has("chip")) | . as $c | (($c.chip|keys)-$ok) as $x | select($x|length>0) | "\($c.slug): chip unknown \($x|join(","))"'

# ── 12b. chip.label string + chip.live boolean ───────────────────────────────
none "every chip has string label + boolean live" \
  '.components[] | select(has("chip")) | select((.chip.label|type)!="string" or (.chip.live|type)!="boolean") | "\(.slug): bad chip label/live types"'

# ── 13-14. chip.processKey / chip.versionKey enums (when present) ────────────
none "every chip.processKey in $PK_ENUM" \
  --argjson e "$PK_ENUM" \
  '.components[] | select(.chip.processKey!=null) | .chip.processKey as $pk | select(($e|index($pk))|not) | "\(.slug): processKey=\($pk)"'
none "every chip.versionKey in $VK_ENUM" \
  --argjson e "$VK_ENUM" \
  '.components[] | select(.chip.versionKey!=null) | .chip.versionKey as $vk | select(($e|index($vk))|not) | "\(.slug): versionKey=\($vk)"'

# ── 15. semantics: slugs unique ──────────────────────────────────────────────
none "component slugs are unique" \
  '[.components[].slug] | group_by(.)[] | select(length>1) | "duplicate slug: \(.[0])"'

# ── 16. semantics: every requires[] target resolves to a catalog slug ────────
none "every requires[] target resolves to a catalog slug" \
  '[.components[].slug] as $s | .components[] | .slug as $sl | (.requires[]? as $r | select(($s|index($r))|not) | "\($sl) requires unknown \($r)")'

if [ "$fail" -ne 0 ]; then echo "TEST FAILED"; exit 1; fi
echo "All checks passed."
