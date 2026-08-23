#!/usr/bin/env bash
# base/tests/test-profiles-schema.sh — profiles-catalog validator (SCRUM-2035).
#
# components.json has had a schema guard since SCRUM-1447; profiles.json never did,
# so `order`/`default`/`components[]` — and now `locked[]` (SCRUM-2035) — could ship
# malformed from the SOURCE OF TRUTH and only fail later, in the portal's vitest
# suite, after someone had already vendored the drift.
#
# This is the profiles-side mirror of test-components-schema.sh: it validates
# profiles.json AGAINST profiles.schema.json, plus the CROSS-FILE semantics a
# JSON-Schema draft cannot express (order/default/components/locked coherence and
# the dispatchability invariant against components.json).
#
# Like its sibling, the constraints are READ FROM THE SCHEMA at runtime (required
# keys, allowed keys, slug pattern) rather than hard-coded, so this validator tracks
# schema edits instead of drifting from them. jq STRUCTURAL validator, deliberately
# NOT ajv-cli/npx: jq is already assumed present and it runs offline.
#
# Schema -> check map (profiles.schema.json):
#   root.required (version/default/order/profiles)  -> sections 2-4
#   $defs.profile.required                          -> section 5
#   $defs.profile additionalProperties:false        -> section 6
#   $defs.profile.properties.slug.pattern           -> section 7
#   default "MUST be one of profiles[].slug"        -> section 8
#   order "MUST list every profiles[].slug once"    -> section 9
#   components[] -> components.json slugs           -> section 11
#   locked[] ⊆ this profile's components[]          -> section 12
#   (cross-file dispatchability invariant)          -> section 13
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-profiles-schema.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
CATALOG="$ROOT/profiles.json"
SCHEMA="$ROOT/profiles.schema.json"
COMPONENTS="$ROOT/components.json"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }
# Assert a jq query over the catalog yields NO offending rows (same contract as
# test-components-schema.sh): everything after the message is forwarded to jq
# verbatim; a non-empty result => violations, listed in the failure.
none() { # <message> <jq-args... filter>
  local msg="$1"; shift
  local out; out="$(jq -r "$@" "$CATALOG" 2>&1)"
  if [ -z "$out" ]; then ok "$msg"; else bad "$msg -> $(printf '%s' "$out" | paste -sd'; ' -)"; fi
}

# ── 1. all three documents are valid JSON ────────────────────────────────────
jq -e . "$CATALOG"    >/dev/null 2>&1 && ok "profiles.json is valid JSON"        || { bad "profiles.json is not valid JSON"; echo "TEST FAILED"; exit 1; }
jq -e . "$SCHEMA"     >/dev/null 2>&1 && ok "profiles.schema.json is valid JSON" || { bad "profiles.schema.json is not valid JSON"; echo "TEST FAILED"; exit 1; }
jq -e . "$COMPONENTS" >/dev/null 2>&1 && ok "components.json is valid JSON"      || { bad "components.json is not valid JSON"; echo "TEST FAILED"; exit 1; }

# Pull the constraints out of the schema so the checks track it.
ROOT_REQ="$(jq -c '.required' "$SCHEMA")"
PROF_REQ="$(jq -c '.["$defs"].profile.required' "$SCHEMA")"
PROF_ALLOWED="$(jq -c '[.["$defs"].profile.properties|keys[]]' "$SCHEMA")"
SLUG_PAT="$(jq -r '.["$defs"].profile.properties.slug.pattern' "$SCHEMA")"

# ── 1b. validator-fidelity guards: the schema must still declare what we encode ─
jq -e '.["$defs"].profile.additionalProperties==false' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema pins profile.additionalProperties:false (validator assumption holds)" \
  || bad "schema no longer pins profile.additionalProperties:false — update this validator"
jq -e 'has("additionalProperties")|not' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema root permits extra top-level keys (so \$schema/runner/aliases are allowed)" \
  || bad "schema root now constrains additionalProperties — this validator must enforce it too"
jq -e '.["$defs"].profile.properties.locked.type=="array"' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema declares profile.locked as an array (validator assumption holds)" \
  || bad "schema no longer declares profile.locked — update this validator"

# ── 2-4. top level ───────────────────────────────────────────────────────────
none "top-level has the schema-required keys $(printf '%s' "$ROOT_REQ" | jq -r 'join(",")')" \
  --argjson req "$ROOT_REQ" \
  '. as $d | ($req-($d|keys)) as $m | select($m|length>0) | "missing \($m|join(","))"'
jq -e '.version|(type=="number" and .>=1 and (.==floor))' "$CATALOG" >/dev/null 2>&1 \
  && ok "version is an integer >= 1" || bad "version is not an integer >= 1"
jq -e '.profiles|(type=="array" and length>=1)' "$CATALOG" >/dev/null 2>&1 \
  && ok "profiles is a non-empty array (minItems 1)" || bad "profiles is not a non-empty array"

# ── 5. each profile carries the schema-required keys ─────────────────────────
none "every profile has the required keys $(printf '%s' "$PROF_REQ" | jq -r 'join(",")')" \
  --argjson req "$PROF_REQ" \
  '.profiles[] | . as $p | ($req-($p|keys)) as $m | select($m|length>0) | "\($p.slug // "?"): missing \($m|join(","))"'

# ── 6. additionalProperties:false at the profile level ───────────────────────
none "no unknown keys on any profile (additionalProperties:false)" \
  --argjson ok "$PROF_ALLOWED" \
  '.profiles[] | . as $p | (($p|keys)-$ok) as $x | select($x|length>0) | "\($p.slug): unknown \($x|join(","))"'

# ── 7. slug pattern ──────────────────────────────────────────────────────────
none "every slug matches $SLUG_PAT" \
  --arg pat "$SLUG_PAT" \
  '.profiles[] | select((.slug|type)!="string" or (.slug|test($pat)|not)) | "\(.slug|tostring) fails slug pattern"'

# ── 8. default resolves to a profile ─────────────────────────────────────────
none "default resolves to a profiles[].slug" \
  '.default as $d | [.profiles[].slug] as $s | select(($s|index($d))|not) | "default=\($d|tostring) is not a profile"'

# ── 9. order lists every slug exactly once, and nothing else ─────────────────
none "order lists every profiles[].slug exactly once (and no unknown slug)" \
  '([.profiles[].slug]|sort) as $s | (.order|sort) as $o | select($o != $s) |
     "order=\($o|join(",")) != profiles=\($s|join(","))"'

# ── 10. semantics: slugs unique; runner/default_roles well-formed ────────────
none "profile slugs are unique" \
  '[.profiles[].slug] | group_by(.)[] | select(length>1) | "duplicate slug: \(.[0])"'
none "every profile.runner equals the catalog runner" \
  '.runner as $r | .profiles[] | select(.runner != $r) | "\(.slug): runner=\(.runner|tostring) != \($r|tostring)"'
none "every default_roles is a non-empty array of strings" \
  '.profiles[] | select((.default_roles|type)!="array" or (.default_roles|length)==0
                        or ([.default_roles[]|select(type!="string")]|length>0)) | "\(.slug): bad default_roles"'
none "every components[] is an array of unique strings" \
  '.profiles[] | select((.components|type)!="array"
                        or ([.components[]|select(type!="string")]|length>0)
                        or ((.components|unique|length) != (.components|length))) | "\(.slug): bad components"'

# ── 11. cross-file: every components[] entry is a components.json slug ───────
none "every profile component slug resolves to a components.json slug" \
  --slurpfile cat "$COMPONENTS" \
  '[$cat[0].components[].slug] as $known | .profiles[] | .slug as $s |
     (.components[] as $c | select(($known|index($c))|not) | "\($s) lists unknown component \($c)")'

# ── 12. locked[] (SCRUM-2035): array of unique strings ⊆ this profile's components
none "every locked is an array of unique strings (when present)" \
  '.profiles[] | select(has("locked")) |
     select((.locked|type)!="array"
            or ([.locked[]|select(type!="string")]|length>0)
            or ((.locked|unique|length) != (.locked|length))) | "\(.slug): bad locked"'
none "every locked[] slug is also in that profile's own components[]" \
  '.profiles[] | .slug as $s | (.components // []) as $own |
     ((.locked // [])[] as $l | select(($own|index($l))|not) | "\($s) locks \($l) which it does not install")'

# ── 13. cross-file invariant: every profile resolves to a DISPATCHABLE agent ──
# The globally-required components (components.json `required:true`) are unioned into
# every agent's set, then closed over `requires`. That closure MUST contain the
# dispatch-unlocking component — otherwise a profile ships an agent the portal cannot
# dispatch to. Enforcement is the portal's (SCRUM-2036); this pins the DATA that makes
# it satisfiable at the source. The server slug is derived from `unlocks`, not hard-coded.
none "every profile's component closure (incl. globally-required) unlocks dispatch" \
  --slurpfile cat "$COMPONENTS" \
  '($cat[0].components | map({key:.slug, value:(.requires // [])}) | from_entries) as $req
   | [$cat[0].components[] | select(.required==true) | .slug] as $global
   | ([$cat[0].components[] | select((.unlocks // []) | index("dispatch")) | .slug] | first) as $server
   | .profiles[] | .slug as $s
   | (($global + (.components // [])) | unique) as $seed
   | ({set:$seed, done:false}
      | until(.done;
          .set as $cur
          | (($cur + ([$cur[] | $req[.] // []] | flatten)) | unique) as $next
          | {set:$next, done:($next == $cur)})
      | .set) as $closed
   | select(($server|type)!="string" or (($closed|index($server))|not))
   | "\($s): closure [\($closed|join(","))] does not unlock dispatch"'

if [ "$fail" -ne 0 ]; then echo "TEST FAILED"; exit 1; fi
echo "All checks passed."
