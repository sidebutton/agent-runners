# 09b-clock.sh — one clock on the agent desktop: the VM's time zone and Claude
# Code's time format (DEV-110).
#
# WHY: no step ever set a zone, so every VM kept the cloud image's Etc/UTC and
# every clock an operator reads — the XFCE panel, the tmux bar (%H:%M, 19h),
# Claude Code's turn footer and usage-limit lines — showed UTC. Claude Code's
# default timeFormat ("auto") also takes its locale from LC_ALL/LC_TIME/LANG,
# cannot use C.UTF-8 and falls back to en-US, so its footer alone printed 12h
# ("done 2:17 PM") beside the 24h bar and panel.
#
# WHAT:
#   * system zone = AGENT_TIMEZONE, default Europe/Berlin (CET/CEST). An IANA
#     name, never "CET": ICU resolves CET to Europe/Brussels and Claude Code
#     prints that label. Only the system zone moves every clock at once; Claude
#     Code's own `timeZone` setting would move just its footer.
#     AGENT_TIMEZONE comes from the install env at provision but only from
#     ~/.agent-env on a refresh (lib-refresh.sh sources nothing else), so an
#     explicit zone is recorded in /etc/sidebutton/timezone and a refresh without
#     AGENT_TIMEZONE keeps it instead of falling back to the default.
#   * "timeFormat": "24-hour" merged into ~/.claude/settings.json, every other
#     key kept. 09 writes that file at provision only and the refresh re-merges
#     only .hooks, so this step is what reaches the fleet.
#   Claude Code (2.1.281) hardcodes en-US 12h for its usage-limit lines ("resets
#   7:40pm (Europe/Berlin)") and reads no setting there — only their zone follows.
#
# ORDER: after 09 (settings.json exists) and before 16/17 start the desktop
# session, Chrome and (19b) the SideButton server, so a new VM starts all of them
# on the new zone. Refresh-safe (refresh-manifest.txt): idempotent root writes,
# no apt, no services touched. A process that resolved its zone before a refresh —
# the shared tmux server, xfce4-panel, a running claude — can keep the old one
# until it restarts, so reboot a refreshed box once it is idle (sb-reboot).
# Never aborts the install: every failure is a WARN.

step "Step 9b/16: time zone + Claude Code time format"

# Overridable only so base/tests/test-09b-clock.sh can sandbox the writes.
SB_ZONEINFO="${SB_ZONEINFO:-/usr/share/zoneinfo}"
SB_LOCALTIME="${SB_LOCALTIME:-/etc/localtime}"
SB_TIMEZONE_FILE="${SB_TIMEZONE_FILE:-/etc/timezone}"
SB_TZ_MARKER="${SB_TZ_MARKER:-/etc/sidebutton/timezone}"

if [ -n "${AGENT_TIMEZONE:-}" ]; then
  SB_TZ="$AGENT_TIMEZONE"
elif [ -s "$SB_TZ_MARKER" ]; then
  SB_TZ="$(head -n 1 "$SB_TZ_MARKER" 2>/dev/null || true)"
else
  SB_TZ="Europe/Berlin"
fi
SB_TZ_PATH="${SB_ZONEINFO}/${SB_TZ}"
# A zone is a TZif file under zoneinfo with an IANA-shaped name (Area/City,
# Etc/GMT+1) — the test timedated itself applies, so the fallback below can never
# install a name timedatectl would refuse. No dot keeps out "../" and the data
# files (zone.tab, tzdata.zi); the TZif magic keeps out the dotless leapseconds;
# "localtime" is Debian's link back to /etc/localtime, which would make
# /etc/localtime a symlink loop; and right/ zones (tzdata-legacy, pulled in by
# chrony) count leap seconds, so the clock would run ~27 s slow.
SB_TZ_RE='^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$'

_clock_zone_is_current() {
  [ "$(readlink -f "$SB_LOCALTIME")" = "$(readlink -f "$SB_TZ_PATH")" ]
}

# timedatectl needs systemd as PID 1; a container agent has none, so the fallback
# writes the symlink timedatectl would (-T: a directory a bind mount left at
# /etc/localtime makes it fail instead of linking inside it). timedatectl leaves
# /etc/timezone alone (systemd 255), and anything that still reads that Debian
# file would go on reporting Etc/UTC, so it follows once /etc/localtime is right.
if ! [[ "$SB_TZ" =~ $SB_TZ_RE ]] || [ "$SB_TZ" = localtime ] || [[ "$SB_TZ" == right/* ]] \
   || [ ! -f "$SB_TZ_PATH" ] || [ "$(head -c 4 "$SB_TZ_PATH" 2>/dev/null)" != TZif ]; then
  log "WARN: unknown time zone '${SB_TZ}' (AGENT_TIMEZONE) — system zone left unchanged"
else
  if _clock_zone_is_current; then
    log "time zone already ${SB_TZ}"
  elif { timedatectl set-timezone "$SB_TZ" 2>/dev/null \
           || ln -sfnT "$SB_TZ_PATH" "$SB_LOCALTIME" 2>/dev/null; } \
       && _clock_zone_is_current; then
    log "time zone set to ${SB_TZ}"
  else
    log "WARN: could not set the time zone to ${SB_TZ} — system zone left unchanged"
  fi
  if _clock_zone_is_current; then
    if [ "$(cat "$SB_TIMEZONE_FILE" 2>/dev/null)" != "$SB_TZ" ] \
       && ! printf '%s\n' "$SB_TZ" 2>/dev/null > "$SB_TIMEZONE_FILE"; then
      log "WARN: could not write ${SB_TZ} to ${SB_TIMEZONE_FILE}"
    fi
    # Only an explicit zone is recorded, so boxes on the default follow the
    # default. To drop an override, set AGENT_TIMEZONE=Europe/Berlin.
    if [ -n "${AGENT_TIMEZONE:-}" ] && [ "$(cat "$SB_TZ_MARKER" 2>/dev/null)" != "$SB_TZ" ] \
       && ! { mkdir -p "$(dirname "$SB_TZ_MARKER")" && printf '%s\n' "$SB_TZ" > "$SB_TZ_MARKER"; } 2>/dev/null; then
      log "WARN: could not record ${SB_TZ} in ${SB_TZ_MARKER} — a refresh would fall back to the default"
    fi
  fi
fi

# Claude Code's timeFormat presets: auto, 12-hour, 24-hour, 24-hour-utc (or a
# strftime pattern). tmp + mv, as in 14 and lib-refresh.sh, so a failed merge
# never corrupts settings.json; the tmp must be non-empty, because jq prints
# nothing and exits 0 on an empty settings.json.
CLAUDE_SETTINGS="${AGENT_HOME}/.claude/settings.json"
if [ ! -f "$CLAUDE_SETTINGS" ]; then
  log "no ${CLAUDE_SETTINGS} — Claude Code time format not set"
elif jq -e '.timeFormat == "24-hour"' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
  log "Claude Code timeFormat already 24-hour"
elif jq '.timeFormat = "24-hour"' "$CLAUDE_SETTINGS" > "${CLAUDE_SETTINGS}.tmp" 2>/dev/null \
     && [ -s "${CLAUDE_SETTINGS}.tmp" ] && mv "${CLAUDE_SETTINGS}.tmp" "$CLAUDE_SETTINGS" 2>/dev/null; then
  chown "${AGENT_USER}:${AGENT_USER}" "$CLAUDE_SETTINGS" 2>/dev/null || true
  log "Claude Code timeFormat set to 24-hour"
else
  rm -f "${CLAUDE_SETTINGS}.tmp" 2>/dev/null || true
  log "WARN: could not set timeFormat in ${CLAUDE_SETTINGS} — file left unchanged"
fi
