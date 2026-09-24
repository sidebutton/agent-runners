#!/usr/bin/env bash
# base/tests/test-09b-clock.sh — guard for base/09b-clock.sh: the VM's time zone and
# Claude Code's time format (DEV-110).
#
# Why this exists: no step ever set a zone, so every agent VM kept the image's
# Etc/UTC, and Claude Code's footer fell back to en-US 12h ("done 2:17 PM") beside
# the 24h tmux bar and panel clock. The fix is one step; this guard pins what makes
# it reach new VMs AND the live fleet, and what keeps it from ever costing an install.
#
# Acceptance:
#   AC1 — wiring: run.sh sources it after 09 (settings.json exists) and before 16/17
#         (units written + desktop started, so they start on the new zone), and
#         refresh-manifest.txt lists it as an entry, not only in a comment
#   AC2 — a UTC box moves to Europe/Berlin via timedatectl, and /etc/timezone agrees
#         (timedatectl on systemd 255 leaves that file stale)
#   AC3 — no systemd (container): the fallback repoints /etc/localtime itself
#   AC4 — AGENT_TIMEZONE overrides the default; an unknown or unsafe name
#         (Mars/Olympus, ../secret, zone.tab, the non-TZif leapseconds, localtime —
#         Debian's link back to /etc/localtime) leaves the zone untouched
#   AC5 — settings.json gains "timeFormat": "24-hour" and keeps every other key;
#         a different timeFormat converges to 24-hour
#   AC6 — re-running is a no-op: no timedatectl call, settings.json byte-identical
#   AC7 — never aborts `set -euo pipefail` (run.sh sources it ungated): broken JSON,
#         no settings.json, a failing timedatectl + ln all exit 0 and write nothing
#
# Pure bash + jq. The zone paths go through the step's SB_ZONEINFO / SB_LOCALTIME /
# SB_TIMEZONE_FILE seams; timedatectl is a shell-function stub, never the real one.
# Run: bash base/tests/test-09b-clock.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
STEP="$BASE/09b-clock.sh"

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

[ -f "$STEP" ] || { bad "base/09b-clock.sh missing"; exit 1; }

# ── AC1: validity + wiring ───────────────────────────────────────────────────
bash -n "$STEP" && ok "bash -n: 09b-clock.sh" || bad "bash -n failed on the step"

# Comments stripped, so prose that names a step cannot satisfy the order check.
RUN="$(sed 's/#.*//' "$BASE/run.sh")"
line_of() { awk -v f="$1" 'index($0, f) { print NR; exit }' <<<"$RUN"; }
n09="$(line_of '/09-agent-user.sh"')"
n09b="$(line_of '/09b-clock.sh"')"
n16="$(line_of '/16-services-prep.sh"')"
n17="$(line_of '/17-services-start.sh"')"
if [ -z "$n09b" ]; then
  bad "AC1 run.sh does not source 09b-clock.sh (new VMs would stay on UTC)"
elif [ -n "$n09" ] && [ -n "$n16" ] && [ -n "$n17" ] \
     && [ "$n09" -lt "$n09b" ] && [ "$n09b" -lt "$n16" ] && [ "$n09b" -lt "$n17" ]; then
  ok "AC1 run.sh sources 09b after 09 and before 16/17 (lines $n09 < $n09b < $n16)"
else
  bad "AC1 09b is out of order in run.sh (09=$n09 09b=$n09b 16=$n16 17=$n17)"
fi

# The manifest as the refresh itself reads it (sb_refresh_manifest_files drops
# comments), so the carve-out note alone does not count as a listing.
MANIFEST_STEPS="$( . "$BASE/lib-refresh.sh"; sb_refresh_manifest_files "$BASE" )"
grep -qx '09b-clock.sh' <<<"$MANIFEST_STEPS" \
  && ok "AC1 refresh-manifest.txt lists 09b-clock.sh (reaches the live fleet)" \
  || bad "AC1 09b-clock.sh is not a refresh-manifest.txt entry"

# ── sandbox ──────────────────────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ZI="$WORK/zoneinfo"
mkdir -p "$ZI/Etc" "$ZI/Europe" "$ZI/America"
for z in Etc/UTC Europe/Berlin America/New_York zone.tab; do printf 'TZif %s\n' "$z" > "$ZI/$z"; done
printf 'not a zone\n' > "$WORK/secret"   # what "../secret" would resolve to
printf '#\tAllowed leap seconds (a dotless data file, not TZif)\n' > "$ZI/leapseconds"

# System dirs only, never the caller's PATH (same reason as test-15b).
SANDBOX_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# new_box <name> [settings-json|-] — a fresh box on the image default (Etc/UTC)
# with a settings.json shaped like base/09's; "-" means no settings.json at all.
new_box() {
  BOX="$WORK/$1"
  mkdir -p "$BOX/etc" "$BOX/home/.claude"
  ln -s "$ZI/Etc/UTC" "$BOX/etc/localtime"
  echo "Etc/UTC" > "$BOX/etc/timezone"
  : > "$BOX/timedatectl.calls"
  if [ "${2-}" = "-" ]; then
    :
  elif [ -n "${2-}" ]; then
    printf '%s' "$2" > "$BOX/home/.claude/settings.json"
  else
    jq -n --slurpfile h "$BASE/assets/claude-hooks.json" '{
      skipDangerousModePermissionPrompt: true,
      env: { DISABLE_AUTOUPDATER: "1" },
      hooks: $h[0].hooks
    }' > "$BOX/home/.claude/settings.json"
  fi
}

# run_step [VAR=value ...] — source the step against $BOX under run.sh's
# `set -euo pipefail` and echo its exit status. Call it as a plain assignment,
# never inside a condition: bash would make errexit inert in the subshell.
# TD_MODE=ok: timedatectl acts like timedated (repoints the symlink only);
# TD_MODE=fail: no systemd, so it fails and the fallback has to act.
run_step() {
  (
    set -euo pipefail
    unset AGENT_TIMEZONE
    export AGENT_HOME="$BOX/home" AGENT_USER="$(id -un)" PATH="$SANDBOX_PATH" \
           SB_ZONEINFO="$ZI" SB_LOCALTIME="$BOX/etc/localtime" \
           SB_TIMEZONE_FILE="$BOX/etc/timezone" TD_MODE=ok
    for kv in "$@"; do export "$kv"; done
    step()  { :; }
    log()   { printf '%s\n' "$*" >> "$BOX/step.log"; }
    chown() { :; }
    timedatectl() {
      printf '%s\n' "$*" >> "$BOX/timedatectl.calls"
      [ "$TD_MODE" = ok ] || return 1
      ln -sfn "$SB_ZONEINFO/$2" "$SB_LOCALTIME"
    }
    # shellcheck source=/dev/null
    . "$STEP"
  ) >/dev/null 2>&1
  echo "$?"
}

zone_of()  { readlink -f "$BOX/etc/localtime"; }
calls()    { grep -c . "$BOX/timedatectl.calls"; }
settings() { printf '%s' "$BOX/home/.claude/settings.json"; }

# ── AC2 + AC5: a fresh UTC box ───────────────────────────────────────────────
new_box fresh
cp "$(settings)" "$WORK/fresh.before.json"
rc="$(run_step)"
[ "$rc" = 0 ] && ok "AC2 fresh box: step exits 0 under set -euo pipefail" || bad "AC2 fresh box: step exited $rc"
[ "$(cat "$BOX/timedatectl.calls")" = "set-timezone Europe/Berlin" ] \
  && ok "AC2 timedatectl set-timezone Europe/Berlin (the default)" \
  || bad "AC2 timedatectl calls wrong: '$(cat "$BOX/timedatectl.calls")'"
[ "$(zone_of)" = "$ZI/Europe/Berlin" ] && ok "AC2 /etc/localtime -> Europe/Berlin" || bad "AC2 /etc/localtime -> $(zone_of)"
[ "$(cat "$BOX/etc/timezone")" = "Europe/Berlin" ] \
  && ok "AC2 /etc/timezone rewritten to Europe/Berlin (timedatectl leaves it stale)" \
  || bad "AC2 /etc/timezone still '$(cat "$BOX/etc/timezone")'"
[ "$(jq -r '.timeFormat' "$(settings)")" = "24-hour" ] \
  && ok "AC5 settings.json timeFormat = 24-hour" || bad "AC5 timeFormat = '$(jq -r '.timeFormat' "$(settings)")'"
if [ "$(jq -S 'del(.timeFormat)' "$(settings)")" = "$(jq -S . "$WORK/fresh.before.json")" ]; then
  ok "AC5 hooks, env and skipDangerousModePermissionPrompt preserved"
else
  bad "AC5 the merge changed keys other than timeFormat"
fi
[ ! -e "$(settings).tmp" ] && ok "AC5 no settings.json.tmp left behind" || bad "AC5 settings.json.tmp left behind"

# ── AC6: re-run on the same box ──────────────────────────────────────────────
cp "$(settings)" "$WORK/fresh.after.json"
: > "$BOX/timedatectl.calls"
rc="$(run_step)"
[ "$rc" = 0 ] && [ "$(calls)" = 0 ] \
  && ok "AC6 re-run: exit 0, no timedatectl call" || bad "AC6 re-run: rc=$rc, timedatectl calls=$(calls)"
cmp -s "$(settings)" "$WORK/fresh.after.json" \
  && ok "AC6 re-run: settings.json byte-identical" || bad "AC6 re-run rewrote settings.json"

# ── AC3: container (no systemd) ──────────────────────────────────────────────
new_box container
rc="$(run_step TD_MODE=fail)"
if [ "$rc" = 0 ] && [ "$(zone_of)" = "$ZI/Europe/Berlin" ] && [ "$(cat "$BOX/etc/timezone")" = "Europe/Berlin" ]; then
  ok "AC3 timedatectl fails: fallback symlinks /etc/localtime + writes /etc/timezone"
else
  bad "AC3 container fallback: rc=$rc localtime=$(zone_of) timezone=$(cat "$BOX/etc/timezone")"
fi

# ── AC2: /etc/localtime already right, /etc/timezone stale ───────────────────
new_box stale
ln -sfn "$ZI/Europe/Berlin" "$BOX/etc/localtime"
rc="$(run_step)"
[ "$rc" = 0 ] && [ "$(cat "$BOX/etc/timezone")" = "Europe/Berlin" ] \
  && ok "AC2 stale /etc/timezone is brought in line with /etc/localtime" \
  || bad "AC2 stale /etc/timezone left as '$(cat "$BOX/etc/timezone")' (rc=$rc)"

# ── AC4: override + rejected names ───────────────────────────────────────────
new_box override
rc="$(run_step AGENT_TIMEZONE=America/New_York)"
if [ "$rc" = 0 ] && [ "$(zone_of)" = "$ZI/America/New_York" ] && [ "$(cat "$BOX/etc/timezone")" = "America/New_York" ]; then
  ok "AC4 AGENT_TIMEZONE=America/New_York overrides the default"
else
  bad "AC4 override: rc=$rc localtime=$(zone_of) timezone=$(cat "$BOX/etc/timezone")"
fi

for name in Mars/Olympus ../secret zone.tab leapseconds localtime; do
  new_box "reject-${name//[^A-Za-z]/_}"
  # As on Ubuntu: zoneinfo/localtime -> /etc/localtime. Accepting it would loop.
  [ "$name" = localtime ] && ln -sfn "$BOX/etc/localtime" "$ZI/localtime"
  rc="$(run_step "AGENT_TIMEZONE=$name")"
  if [ "$rc" = 0 ] && [ "$(calls)" = 0 ] && [ "$(zone_of)" = "$ZI/Etc/UTC" ] \
     && [ "$(cat "$BOX/etc/timezone")" = "Etc/UTC" ] && grep -q "WARN: unknown time zone" "$BOX/step.log"; then
    ok "AC4 AGENT_TIMEZONE='$name' rejected: WARN, zone untouched, exit 0"
  else
    bad "AC4 AGENT_TIMEZONE='$name': rc=$rc calls=$(calls) localtime=$(zone_of)"
  fi
done
[ "$(jq -r '.timeFormat' "$(settings)")" = "24-hour" ] \
  && ok "AC4 a rejected zone still sets timeFormat (the halves are independent)" \
  || bad "AC4 a rejected zone also skipped timeFormat"

# ── AC5: a different timeFormat converges ────────────────────────────────────
new_box twelve '{"timeFormat": "12-hour", "env": {"DISABLE_AUTOUPDATER": "1"}}'
rc="$(run_step)"
[ "$rc" = 0 ] && [ "$(jq -c . "$(settings)")" = '{"timeFormat":"24-hour","env":{"DISABLE_AUTOUPDATER":"1"}}' ] \
  && ok "AC5 timeFormat 12-hour converges to 24-hour, env kept" \
  || bad "AC5 12-hour box: rc=$rc settings=$(jq -c . "$(settings)" 2>&1)"

# ── AC7: failure paths never abort the install ───────────────────────────────
new_box broken '{"hooks": '
cp "$(settings)" "$WORK/broken.before.json"
rc="$(run_step)"
if [ "$rc" = 0 ] && cmp -s "$(settings)" "$WORK/broken.before.json" && [ ! -e "$(settings).tmp" ] \
   && grep -q "WARN: could not set timeFormat" "$BOX/step.log"; then
  ok "AC7 broken settings.json: WARN, file untouched, no .tmp, exit 0"
else
  bad "AC7 broken settings.json: rc=$rc (file changed, .tmp left or no WARN)"
fi

new_box nosettings -
rc="$(run_step)"
[ "$rc" = 0 ] && [ ! -e "$(settings)" ] \
  && ok "AC7 no settings.json: exit 0, file not created" || bad "AC7 no settings.json: rc=$rc or file created"

new_box unwritable
rc="$(run_step TD_MODE=fail "SB_LOCALTIME=$BOX/missing/localtime")"
if [ "$rc" = 0 ] && [ "$(cat "$BOX/etc/timezone")" = "Etc/UTC" ] && grep -q "WARN: could not set the time zone" "$BOX/step.log"; then
  ok "AC7 timedatectl and the fallback both fail: WARN, /etc/timezone untouched, exit 0"
else
  bad "AC7 zone write failure: rc=$rc timezone=$(cat "$BOX/etc/timezone")"
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
