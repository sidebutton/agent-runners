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
#         (timedatectl on systemd 255 leaves that file stale); a stale /etc/timezone
#         alone is rewritten without a timedatectl call
#   AC3 — no systemd (container): the fallback repoints /etc/localtime itself
#   AC4 — AGENT_TIMEZONE overrides the default, and is applied by name (a tzdata
#         link such as Europe/Busingen -> Zurich is not "already current"). Without
#         it the default replaces only UTC (or a missing /etc/localtime): a zone set at
#         install — which a refresh cannot see, it only reads ~/.agent-env — or by hand
#         is left alone. An unknown or unsafe name (Mars/Olympus, ../secret, zone.tab,
#         the non-TZif leapseconds, localtime — Debian's link back to /etc/localtime —
#         and leap-second right/ zones) leaves the zone untouched
#   AC5 — settings.json gains "timeFormat": "24-hour" and keeps every other key;
#         a different timeFormat converges to 24-hour
#   AC6 — re-running is a no-op: no timedatectl call, settings.json byte-identical
#   AC7 — never aborts `set -euo pipefail` (run.sh sources it ungated): broken or
#         empty JSON, no settings.json, a failing timedatectl + ln, a directory at
#         /etc/localtime all exit 0 and write nothing; an unwritable /etc/timezone
#         WARNs about that file only
#   AC8 — Claude Code's reset times (DEV-284): with a real claude on PATH the step
#         writes the shim and a marked /usr/local/bin/claude wrapper; the wrapper
#         execs the next claude on PATH with --preload=<shim> prepended to
#         BUN_OPTIONS (none when the shim is unreadable); no real claude => no
#         wrapper (it would satisfy `command -v claude`), and ours is removed; a
#         foreign /usr/local/bin/claude is never touched; a re-run rewrites nothing
#   AC9 — the shim, run on Claude Code 2.1.292's reset formatter (copied verbatim):
#         timeFormat 24-hour gives "Oct 10, 02:00 (Europe/Berlin)" and "HH:MM";
#         auto, another locale and a non-claude process are untouched; it strips
#         itself from BUN_OPTIONS and never throws on a broken settings.json.
#         Under node always; under the box's real claude.exe (Bun) when present
#
# Pure bash + jq (+ node for AC9). The zone paths go through the step's SB_ZONEINFO /
# SB_LOCALTIME / SB_TIMEZONE_FILE seams, the shim and wrapper through SB_CLAUDE_SHIM /
# SB_CLAUDE_WRAPPER; timedatectl is a shell-function stub, never the real one.
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
mkdir -p "$ZI/Etc" "$ZI/Europe" "$ZI/America" "$ZI/right/Europe"
for z in Etc/UTC Europe/Berlin Europe/Zurich America/New_York zone.tab right/Europe/Berlin; do printf 'TZif %s\n' "$z" > "$ZI/$z"; done
ln -s Zurich "$ZI/Europe/Busingen"   # a tzdata link, as on Ubuntu
printf 'not a zone\n' > "$WORK/secret"   # what "../secret" would resolve to
printf '#\tAllowed leap seconds (a dotless data file, not TZif)\n' > "$ZI/leapseconds"

# System dirs only, never the caller's PATH (same reason as test-15b) — and with no
# `claude`: an agent VM has a real one in /usr/bin, so every system executable but
# claude is farmed into one dir (as test-19i does). Each box brings its own claude.
NOCLAUDE="$WORK/.sysbin"; mkdir -p "$NOCLAUDE"
for d in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    [ "$b" = claude ] || [ -e "$NOCLAUDE/$b" ] || ln -s "$f" "$NOCLAUDE/$b" 2>/dev/null || true
  done
done

# new_box <name> [settings-json|-] — a fresh box on the image default (Etc/UTC)
# with a settings.json shaped like base/09's; "-" means no settings.json at all.
# $BOX/bin stands in for /usr/local/bin and $BOX/npm for npm's /usr/bin, whose
# `claude` stub prints how it was called (no claude: rm it).
new_box() {
  BOX="$WORK/$1"
  mkdir -p "$BOX/etc" "$BOX/home/.claude" "$BOX/bin" "$BOX/npm"
  printf '#!/bin/bash\nprintf "argv0=%%s BUN_OPTIONS=[%%s] args=%%s\\n" "$0" "${BUN_OPTIONS-}" "$*"\n' > "$BOX/npm/claude"
  chmod 0755 "$BOX/npm/claude"
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
# TD_MODE=fail: no systemd, so it fails and the fallback has to act;
# TD_MODE=noop: it reports success but /etc/localtime does not change.
run_step() {
  (
    set -euo pipefail
    unset AGENT_TIMEZONE
    export AGENT_HOME="$BOX/home" AGENT_USER="$(id -un)" PATH="$BOX/bin:$BOX/npm:$NOCLAUDE" \
           SB_ZONEINFO="$ZI" SB_LOCALTIME="$BOX/etc/localtime" \
           SB_TIMEZONE_FILE="$BOX/etc/timezone" TD_MODE=ok \
           SB_CLAUDE_SHIM="$BOX/lib/claude-clock-24h.js" SB_CLAUDE_WRAPPER="$BOX/bin/claude"
    for kv in "$@"; do export "$kv"; done
    step()  { :; }
    log()   { printf '%s\n' "$*" >> "$BOX/step.log"; }
    chown() { :; }
    timedatectl() {
      printf '%s\n' "$*" >> "$BOX/timedatectl.calls"
      [ "$TD_MODE" = noop ] && return 0
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
[ "$rc" = 0 ] && [ "$(cat "$BOX/etc/timezone")" = "Europe/Berlin" ] && [ "$(calls)" = 0 ] \
  && grep -q "time zone already Europe/Berlin" "$BOX/step.log" \
  && ok "AC2 stale /etc/timezone is brought in line with /etc/localtime, no timedatectl call" \
  || bad "AC2 stale /etc/timezone: '$(cat "$BOX/etc/timezone")' rc=$rc timedatectl calls=$(calls)"

# ── AC4: override + rejected names ───────────────────────────────────────────
new_box override
rc="$(run_step AGENT_TIMEZONE=America/New_York)"
if [ "$rc" = 0 ] && [ "$(zone_of)" = "$ZI/America/New_York" ] && [ "$(cat "$BOX/etc/timezone")" = "America/New_York" ]; then
  ok "AC4 AGENT_TIMEZONE=America/New_York overrides the default"
else
  bad "AC4 override: rc=$rc localtime=$(zone_of) timezone=$(cat "$BOX/etc/timezone")"
fi
# A refresh sources only ~/.agent-env, so the install-time AGENT_TIMEZONE is gone.
: > "$BOX/timedatectl.calls"
rc="$(run_step)"
if [ "$rc" = 0 ] && [ "$(zone_of)" = "$ZI/America/New_York" ] && [ "$(calls)" = 0 ] \
   && [ "$(cat "$BOX/etc/timezone")" = "America/New_York" ] && grep -q "time zone left as is" "$BOX/step.log"; then
  ok "AC4 a refresh without AGENT_TIMEZONE keeps America/New_York, not the default"
else
  bad "AC4 refresh without AGENT_TIMEZONE: rc=$rc localtime=$(zone_of) timedatectl calls=$(calls)"
fi
rc="$(run_step AGENT_TIMEZONE=Europe/Berlin)"
[ "$rc" = 0 ] && [ "$(zone_of)" = "$ZI/Europe/Berlin" ] && [ "$(cat "$BOX/etc/timezone")" = "Europe/Berlin" ] \
  && ok "AC4 AGENT_TIMEZONE=Europe/Berlin moves an overridden box back" \
  || bad "AC4 moving back to Europe/Berlin: rc=$rc localtime=$(zone_of)"

new_box byhand
ln -sfn "$ZI/America/New_York" "$BOX/etc/localtime"   # timedatectl by hand; /etc/timezone left stale
rc="$(run_step)"
if [ "$rc" = 0 ] && [ "$(calls)" = 0 ] && [ "$(zone_of)" = "$ZI/America/New_York" ] \
   && [ "$(cat "$BOX/etc/timezone")" = "Etc/UTC" ] && grep -q "time zone left as is" "$BOX/step.log"; then
  ok "AC4 no AGENT_TIMEZONE: a zone set by hand is left alone (the default only replaces UTC)"
else
  bad "AC4 zone set by hand: rc=$rc calls=$(calls) localtime=$(zone_of) timezone=$(cat "$BOX/etc/timezone")"
fi

new_box nolocaltime
rm -f "$BOX/etc/localtime"   # a minimal container image ships none (glibc reads that as UTC)
rc="$(run_step TD_MODE=fail)"
[ "$rc" = 0 ] && [ "$(zone_of)" = "$ZI/Europe/Berlin" ] && [ "$(cat "$BOX/etc/timezone")" = "Europe/Berlin" ] \
  && ok "AC4 no /etc/localtime counts as UTC: the default applies" \
  || bad "AC4 missing /etc/localtime: rc=$rc localtime=$(zone_of) timezone=$(cat "$BOX/etc/timezone")"

new_box link
ln -sfn "$ZI/Europe/Zurich" "$BOX/etc/localtime" && echo "Europe/Zurich" > "$BOX/etc/timezone"
rc="$(run_step AGENT_TIMEZONE=Europe/Busingen)"
if [ "$rc" = 0 ] && [ "$(cat "$BOX/timedatectl.calls")" = "set-timezone Europe/Busingen" ] \
   && [ "$(readlink "$BOX/etc/localtime")" = "$ZI/Europe/Busingen" ] && [ "$(cat "$BOX/etc/timezone")" = "Europe/Busingen" ]; then
  ok "AC4 Europe/Busingen on a Europe/Zurich box is applied by name, not taken as already current"
else
  bad "AC4 link name: rc=$rc calls='$(cat "$BOX/timedatectl.calls")' localtime=$(readlink "$BOX/etc/localtime") timezone=$(cat "$BOX/etc/timezone")"
fi

for name in Mars/Olympus ../secret zone.tab leapseconds localtime right/Europe/Berlin; do
  new_box "reject-${name//[^A-Za-z]/_}"
  # As on Ubuntu: zoneinfo/localtime -> /etc/localtime. Accepting it would loop.
  [ "$name" = localtime ] && ln -sfn "$BOX/etc/localtime" "$ZI/localtime"
  rc="$(run_step "AGENT_TIMEZONE=$name")"
  tf="$(jq -r '.timeFormat' "$(settings)" 2>/dev/null)"
  if [ "$rc" = 0 ] && [ "$(calls)" = 0 ] && [ "$(zone_of)" = "$ZI/Etc/UTC" ] \
     && [ "$(cat "$BOX/etc/timezone")" = "Etc/UTC" ] && grep -q "WARN: unknown time zone" "$BOX/step.log" \
     && [ "$tf" = "24-hour" ]; then
    ok "AC4 AGENT_TIMEZONE='$name' rejected: WARN, zone untouched, timeFormat still set, exit 0"
  else
    bad "AC4 AGENT_TIMEZONE='$name': rc=$rc calls=$(calls) localtime=$(zone_of) timezone=$(cat "$BOX/etc/timezone") timeFormat=$tf log=$(tr '\n' '|' < "$BOX/step.log")"
  fi
done

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

new_box noop
rc="$(run_step TD_MODE=noop)"
if [ "$rc" = 0 ] && [ "$(zone_of)" = "$ZI/Etc/UTC" ] && [ "$(cat "$BOX/etc/timezone")" = "Etc/UTC" ] \
   && grep -q "WARN: could not set the time zone" "$BOX/step.log" && ! grep -q "time zone set to" "$BOX/step.log"; then
  ok "AC7 timedatectl reports success but /etc/localtime is unchanged: WARN, not 'set', /etc/timezone untouched"
else
  bad "AC7 no-op timedatectl: rc=$rc localtime=$(zone_of) timezone=$(cat "$BOX/etc/timezone")"
fi

new_box tzfile
rc="$(run_step "SB_TIMEZONE_FILE=$BOX/missing/timezone")"
if [ "$rc" = 0 ] && [ "$(zone_of)" = "$ZI/Europe/Berlin" ] \
   && grep -q "WARN: could not write Europe/Berlin to" "$BOX/step.log" \
   && ! grep -q "WARN: could not set the time zone" "$BOX/step.log"; then
  ok "AC7 unwritable /etc/timezone: the zone still moves and only that file is WARNed, exit 0"
else
  bad "AC7 unwritable /etc/timezone: rc=$rc localtime=$(zone_of) log=$(tr '\n' '|' < "$BOX/step.log")"
fi

# A container bind mount of a missing host file leaves a directory at /etc/localtime.
new_box dirlocaltime
rm -f "$BOX/etc/localtime" && mkdir "$BOX/etc/localtime"
rc="$(run_step TD_MODE=fail)"
if [ "$rc" = 0 ] && [ -z "$(ls -A "$BOX/etc/localtime")" ] && [ "$(cat "$BOX/etc/timezone")" = "Etc/UTC" ] \
   && grep -q "WARN: could not set the time zone" "$BOX/step.log"; then
  ok "AC7 a directory at /etc/localtime: WARN, no link made inside it, /etc/timezone untouched, exit 0"
else
  bad "AC7 directory at /etc/localtime: rc=$rc inside=$(ls -A "$BOX/etc/localtime") timezone=$(cat "$BOX/etc/timezone")"
fi

new_box empty
: > "$(settings)"
rc="$(run_step)"
if [ "$rc" = 0 ] && [ ! -s "$(settings)" ] && [ ! -e "$(settings).tmp" ] \
   && grep -q "WARN: could not set timeFormat" "$BOX/step.log" && ! grep -q "timeFormat set to" "$BOX/step.log"; then
  ok "AC7 empty settings.json: WARN (no false 'set'), file untouched, no .tmp, exit 0"
else
  bad "AC7 empty settings.json: rc=$rc (false success, file changed, .tmp left or no WARN)"
fi

# ── AC8: the reset-time wrapper + shim (DEV-284) ─────────────────────────────
new_box shim
rc="$(run_step)"
W="$BOX/bin/claude"; SHIM="$BOX/lib/claude-clock-24h.js"
if [ "$rc" = 0 ] && [ -x "$W" ] && [ -f "$SHIM" ] && grep -qF 'sidebutton-claude-clock-wrapper (DEV-284)' "$W" \
   && [ "$(stat -c %a "$W")" = 755 ] && [ "$(stat -c %a "$SHIM")" = 644 ] && grep -qF "shim=\"$SHIM\"" "$W" \
   && bash -n "$W" && grep -q "24h shim at" "$BOX/step.log"; then
  ok "AC8 real claude on PATH: shim (0644) + marked wrapper (0755) pointing at it"
else
  bad "AC8 install: rc=$rc wrapper=$(ls -l "$W" 2>&1) shim=$(ls -l "$SHIM" 2>&1) log=$(tr '\n' '|' < "$BOX/step.log")"
fi
out="$(PATH="$BOX/bin:$BOX/npm:$NOCLAUDE" BUN_OPTIONS="--smol" claude -p 'a b' 2>&1)"
[ "$out" = "argv0=$BOX/npm/claude BUN_OPTIONS=[--preload=$SHIM --smol] args=-p a b" ] \
  && ok "AC8 wrapper execs the next claude with --preload=<shim> prepended, args intact" \
  || bad "AC8 wrapper run: '$out'"
out="$(PATH="$BOX/bin:$BOX/npm:$NOCLAUDE" env -u BUN_OPTIONS claude --version 2>&1)"
[ "$out" = "argv0=$BOX/npm/claude BUN_OPTIONS=[--preload=$SHIM] args=--version" ] \
  && ok "AC8 wrapper with no BUN_OPTIONS of its own sets just the preload" || bad "AC8 wrapper, no BUN_OPTIONS: '$out'"
chmod 000 "$SHIM"
if [ -r "$SHIM" ]; then
  ok "AC8 unreadable-shim case skipped (running as root)"
else
  out="$(PATH="$BOX/bin:$BOX/npm:$NOCLAUDE" env -u BUN_OPTIONS claude x 2>&1)"
  [ "$out" = "argv0=$BOX/npm/claude BUN_OPTIONS=[] args=x" ] \
    && ok "AC8 unreadable shim: plain exec, no --preload (a missing preload would stop claude)" \
    || bad "AC8 unreadable shim: '$out'"
fi
chmod 644 "$SHIM"
out="$(PATH="$BOX/bin:$NOCLAUDE" claude x 2>&1)"; wrc=$?
[ "$wrc" = 127 ] && grep -q "not installed" <<<"$out" \
  && ok "AC8 wrapper with no claude behind it: exit 127, says so (no exec loop)" || bad "AC8 lone wrapper: rc=$wrc '$out'"
touch -d '2001-01-01' "$W" "$SHIM"
rc="$(run_step)"
[ "$rc" = 0 ] && [ "$(stat -c %Y "$W")" = "$(date -d 2001-01-01 +%s)" ] && [ "$(stat -c %Y "$SHIM")" = "$(date -d 2001-01-01 +%s)" ] \
  && [ -z "$(find "$BOX/bin" "$BOX/lib" -name '*.??????' 2>/dev/null)" ] \
  && ok "AC8 re-run: wrapper and shim not rewritten, no temp files left" || bad "AC8 re-run rewrote the wrapper/shim (rc=$rc)"

rm -f "$BOX/npm/claude"
rc="$(run_step)"
[ "$rc" = 0 ] && [ ! -e "$W" ] && grep -q "reset-time wrapper removed" "$BOX/step.log" \
  && ok "AC8 Claude Code gone: our wrapper is removed (it would answer \`command -v claude\`)" \
  || bad "AC8 no claude, wrapper left: rc=$rc $(ls -l "$W" 2>&1)"

new_box claudeless
rm -f "$BOX/npm/claude"
rc="$(run_step)"
[ "$rc" = 0 ] && [ ! -e "$BOX/bin/claude" ] && [ ! -e "$BOX/lib" ] && grep -q "shim not installed" "$BOX/step.log" \
  && ok "AC8 no Claude Code: no wrapper, no shim (the claude-code install and 19i gate on \`command -v claude\`)" \
  || bad "AC8 no claude: rc=$rc bin=$(ls "$BOX/bin") log=$(tr '\n' '|' < "$BOX/step.log")"

new_box foreign
printf '#!/bin/sh\necho real\n' > "$BOX/bin/claude"; chmod 0755 "$BOX/bin/claude"; cp "$BOX/bin/claude" "$WORK/foreign.before"
rc="$(run_step)"
[ "$rc" = 0 ] && cmp -s "$BOX/bin/claude" "$WORK/foreign.before" && grep -q "WARN: .*is not ours" "$BOX/step.log" \
  && [ "$(jq -r .timeFormat "$(settings)")" = 24-hour ] \
  && ok "AC8 a foreign /usr/local/bin/claude is left alone (WARN), timeFormat still set" \
  || bad "AC8 foreign claude: rc=$rc log=$(tr '\n' '|' < "$BOX/step.log")"

new_box unwritable-lib
rc="$(run_step "SB_CLAUDE_SHIM=$BOX/etc/timezone/x/claude-clock-24h.js")"
[ "$rc" = 0 ] && [ ! -e "$BOX/bin/claude" ] && grep -q "WARN: could not write .*claude-clock-24h.js" "$BOX/step.log" \
  && ok "AC8 shim cannot be written: WARN, no wrapper, exit 0" || bad "AC8 unwritable shim dir: rc=$rc"

# ── AC9: the shim on Claude Code's own reset formatter ───────────────────────
CFG="$WORK/cfg"; mkdir -p "$CFG/24" "$CFG/auto" "$CFG/broken"
echo '{"timeFormat":"24-hour"}' > "$CFG/24/settings.json"
echo '{"timeFormat":"auto"}' > "$CFG/auto/settings.json"
echo '{"timeFormat":' > "$CFG/broken/settings.json"
# Yu() and ngo() from claude.exe 2.1.292 (chunk-3s9gnsfk.js), verbatim but for the
# ngo cache variable. MODE=claude pretends to be claude.exe (the shim's own gate).
cat > "$WORK/probe.js" <<'EOF'
let g;function ngo(){if(!g)g=Intl.DateTimeFormat().resolvedOptions().timeZone;return g}
function Yu(e,t=!1,r=!0,n=!1){if(!e)return;let s=new Date(e*1000),o=new Date,c=s.getMinutes(),m=(s.getTime()-o.getTime())/3600000;if(n||m>24){let f={month:"short",day:"numeric",hour:r?"numeric":void 0,minute:!r||c===0?void 0:"2-digit",hour12:r?!0:void 0};if(s.getFullYear()!==o.getFullYear())f.year="numeric";return s.toLocaleString("en-US",f).replace(/[  ]([AP]M)/i,(i,d)=>d.toLowerCase())+(t?` (${ngo()})`:"")}return s.toLocaleTimeString("en-US",{hour:"numeric",minute:c===0?void 0:"2-digit",hour12:!0}).replace(/[  ]([AP]M)/i,(f,a)=>a.toLowerCase())+(t?` (${ngo()})`:"")}
const y = new Date().getFullYear();
const day = Date.UTC(y, 9, 10, 0, 0) / 1000;                     // Oct 10, 02:00 CEST
const soon = new Date(Date.now() + 3 * 3600e3); soon.setMinutes(20, 0, 0);
const out = [Yu(day, true, true, true), Yu(Math.floor(soon / 1000), true),
  new Date(day * 1000).toLocaleString("de-DE", { hour: "numeric", hour12: true }),
  "BUN_OPTIONS=" + (process.env.BUN_OPTIONS ?? "(unset)")];
console.log(out.join(" | "));
process.exit(0);
EOF
if command -v node >/dev/null 2>&1; then
  probe_node() {  # <config dir> — the shim first, as the wrapper's preload would load it
    env TZ=Europe/Berlin CLAUDE_CONFIG_DIR="$1" BUN_OPTIONS="--preload=$WORK/shim/lib/claude-clock-24h.js --smol" \
      node -e 'if (process.env.MODE === "claude") Object.defineProperty(process, "execPath", { value: "/usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" });
               require(process.argv[1]); require(process.argv[2]);' "$WORK/shim/lib/claude-clock-24h.js" "$WORK/probe.js" 2>&1
  }
  out="$(MODE=claude probe_node "$CFG/24")"
  if [[ "$out" =~ ^"Oct 10, 02:00 (Europe/Berlin) | "[0-2][0-9]":20 (Europe/Berlin) | ".*" | BUN_OPTIONS=--smol"$ ]]; then
    ok "AC9 node, timeFormat 24-hour: '${out%% | BUN*}', and the shim left BUN_OPTIONS=--smol"
  else
    bad "AC9 node, 24-hour: '$out'"
  fi
  [[ "$out" == *" | 2"*"AM | "* ]] \
    && ok "AC9 another locale's hour12 call is untouched" || bad "AC9 de-DE call changed: '$out'"
  out="$(MODE=claude probe_node "$CFG/auto")"
  [[ "$out" =~ ^"Oct 10, 2am (Europe/Berlin) | "[0-9]+":20"[ap]"m (Europe/Berlin) | " ]] \
    && ok "AC9 timeFormat auto: shipped 12h output unchanged ('${out%% | *}')" || bad "AC9 auto: '$out'"
  out="$(MODE=claude probe_node "$CFG/broken")"
  [[ "$out" == "Oct 10, 2am (Europe/Berlin) | "* ]] \
    && ok "AC9 broken settings.json: no throw, shipped output" || bad "AC9 broken settings: '$out'"
  out="$(MODE=node probe_node "$CFG/24")"
  [[ "$out" == "Oct 10, 2am (Europe/Berlin) | "*"BUN_OPTIONS=--smol" ]] \
    && ok "AC9 not claude (plain node/bun): Date untouched, preload still stripped" || bad "AC9 non-claude: '$out'"
else
  ok "AC9 node not installed — shim unit cases skipped"
fi
REAL="$(PATH="$NOCLAUDE:/usr/bin:/usr/local/bin" command -v claude 2>/dev/null)"
if [ -n "$REAL" ] && head -c 4 "$(readlink -f "$REAL")" | grep -q ELF \
   && grep -qa 'BUN_OPTIONS' "$(readlink -f "$REAL")" 2>/dev/null; then
  out="$(env -i HOME="$WORK" TZ=Europe/Berlin CLAUDE_CONFIG_DIR="$CFG/24" \
         BUN_OPTIONS="--preload=$WORK/shim/lib/claude-clock-24h.js --preload=$WORK/probe.js" \
         timeout 60 "$REAL" --version 2>&1)"
  if [[ "$out" =~ ^"Oct 10, 02:00 (Europe/Berlin) | "[0-2][0-9]":20 (Europe/Berlin) | ".*" | BUN_OPTIONS=--preload=$WORK/probe.js"$ ]]; then
    ok "AC9 the box's real claude ($("$REAL" --version 2>/dev/null)): '${out%% | 2*}'"
  else
    bad "AC9 real claude: '$out'"
  fi
else
  ok "AC9 no Bun-built claude on this host — real-runtime case skipped"
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
