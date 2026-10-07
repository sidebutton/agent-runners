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
#   * system zone = AGENT_TIMEZONE, default Europe/Berlin (CET/CEST) — an
#     Area/City name, not "CET": ICU resolves CET to Europe/Brussels and Claude
#     Code prints that label. Only the system zone moves every clock at once;
#     Claude Code's own `timeZone` setting would move just its footer.
#     Without AGENT_TIMEZONE the default replaces only the image's UTC (or an
#     /etc/localtime that is no zone file at all, which glibc reads as UTC).
#     A refresh sees AGENT_TIMEZONE only through ~/.agent-env (lib-refresh.sh
#     sources nothing else), so a zone chosen at install, or by hand with
#     timedatectl, must not be taken for "unset" and overwritten.
#   * "timeFormat": "24-hour" merged into ~/.claude/settings.json, every other
#     key kept. 09 writes that file at provision only and the refresh re-merges
#     only .hooks, so this step is what reaches the fleet.
#   * Claude Code's usage-limit and reset times in 24h (DEV-284). Its one reset
#     formatter (2.1.281 … 2.1.292) hardcodes toLocale{,Time}String("en-US",
#     {hour12: true}) and reads no setting or locale, so the footer said "done 13:08"
#     while /usage said "Resets 1:20pm" and the limit notice "resets Oct 10, 2am".
#     claude.exe runs Bun bytecode, so its text cannot be patched; Bun does honour
#     BUN_OPTIONS=--preload. /usr/local/bin/claude (ahead of npm's /usr/bin/claude
#     on every PATH) execs the real claude with a small preload that, while
#     settings.json says 24-hour, turns exactly that call shape into the footer's
#     h23 clock ("resets Oct 10, 02:00 (Europe/Berlin)", "Resets 13:20"). The
#     bundle has no other hour12:true call; everything else passes through. Once
#     upstream honours timeFormat there, the call shape disappears and the preload
#     matches nothing.
#
# ORDER: after 09 (settings.json exists) and before 16/17 start the desktop
# session, Chrome and (19b) the SideButton server, so a new VM starts all of them
# on the new zone. Refresh-safe (refresh-manifest.txt): idempotent root writes,
# no apt, no services touched. A process that resolved its zone before a refresh —
# the shared tmux server, xfce4-panel, a running claude — can keep the old one
# until it restarts, so reboot a refreshed box once it is idle (sb-reboot).
# Never aborts the install: every failure is a WARN.

step "Step 9b/16: time zone + Claude Code time format"

SB_TZ="${AGENT_TIMEZONE:-Europe/Berlin}"
# Overridable only so base/tests/test-09b-clock.sh can sandbox the writes.
SB_ZONEINFO="${SB_ZONEINFO:-/usr/share/zoneinfo}"
SB_LOCALTIME="${SB_LOCALTIME:-/etc/localtime}"
SB_TIMEZONE_FILE="${SB_TIMEZONE_FILE:-/etc/timezone}"
SB_TZ_PATH="${SB_ZONEINFO}/${SB_TZ}"
# A zone is a TZif file under zoneinfo with an IANA-shaped name (Area/City,
# Etc/GMT+1) — the test timedated itself applies, so the fallback below can never
# install a name timedatectl would refuse. No dot keeps out "../" and the data
# files (zone.tab, tzdata.zi); the TZif magic keeps out the dotless leapseconds;
# "localtime" is Debian's link back to /etc/localtime, which would make
# /etc/localtime a symlink loop; and right/ zones (tzdata-legacy, pulled in by
# chrony) count leap seconds, so the clock would run ~27 s slow.
SB_TZ_RE='^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$'

# The zone /etc/localtime names is its link target below zoneinfo/, as
# timedatectl reads it. Resolving the link instead would call a box on
# Europe/Zurich current for Europe/Busingen, a tzdata link to it.
_clock_zone_is_current() {
  local target
  target="$(readlink "$SB_LOCALTIME" 2>/dev/null)" || return 1
  [ "${target##*zoneinfo/}" = "$SB_TZ" ] && [ -e "$SB_LOCALTIME" ]
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
  elif [ -z "${AGENT_TIMEZONE:-}" ] && [ -f "$SB_LOCALTIME" ] \
       && ! cmp -s "$SB_LOCALTIME" "${SB_ZONEINFO}/Etc/UTC"; then
    log "time zone left as is: not UTC and no AGENT_TIMEZONE (the default ${SB_TZ} only replaces UTC)"
  elif { timedatectl set-timezone "$SB_TZ" 2>/dev/null \
           || ln -sfnT "$SB_TZ_PATH" "$SB_LOCALTIME" 2>/dev/null; } \
       && _clock_zone_is_current; then
    log "time zone set to ${SB_TZ}"
  else
    log "WARN: could not set the time zone to ${SB_TZ} — system zone left unchanged"
  fi
  if _clock_zone_is_current && [ "$(cat "$SB_TIMEZONE_FILE" 2>/dev/null)" != "$SB_TZ" ] \
     && ! printf '%s\n' "$SB_TZ" 2>/dev/null > "$SB_TIMEZONE_FILE"; then
    log "WARN: could not write ${SB_TZ} to ${SB_TIMEZONE_FILE}"
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

# The reset-time shim (see WHY/WHAT). Two root-owned files, each written only when
# its bytes differ (tmp + mv). The wrapper exists only while a real claude does: a
# wrapper alone would answer `command -v claude`, which gates the Claude Code
# install (components/claude-code/install.sh) and 19i. A /usr/local/bin/claude that
# is not ours (no marker: e.g. an npm prefix of /usr/local) is never touched.
# Failure modes stay harmless: the wrapper preloads only a readable shim (a missing
# --preload file would stop claude from starting), the shim swallows its own errors
# and acts only inside Claude Code, and it removes itself from BUN_OPTIONS so no
# bun a session runs (bun test …) inherits it.
# Overridable only so base/tests/test-09b-clock.sh can sandbox the writes. Both
# land in a sed replacement and the wrapper's text, so they must be plain absolute
# paths with the default basenames (the shim's self-strip matches its own name).
SB_CLAUDE_SHIM="${SB_CLAUDE_SHIM:-/usr/local/lib/sidebutton/claude-clock-24h.js}"
SB_CLAUDE_WRAPPER="${SB_CLAUDE_WRAPPER:-/usr/local/bin/claude}"
SB_CLAUDE_PATH_RE='^/[A-Za-z0-9._/-]+$'
# The ownership marker. Keep it stable: a wrapper without it is "not ours" and is
# never rewritten or removed again (components/claude-code/install.sh matches it too).
SB_CLAUDE_MARK="sidebutton-claude-clock-wrapper"

# _clock_ours <file> — 0 when <file> carries our marker. Reads only its head: with
# an npm prefix of /usr/local the path is npm's link to the ~250 MB claude.exe.
_clock_ours() { grep -qF "$SB_CLAUDE_MARK" < <(head -c 4096 "$1" 2>/dev/null); }

# _clock_put <dest> <mode> — stdin to <dest>, only when the bytes differ.
_clock_put() {
  local dest="$1" mode="$2" tmp
  tmp="$(mktemp "${dest}.XXXXXX" 2>/dev/null)" || return 1
  if ! cat > "$tmp" || ! chmod "$mode" "$tmp"; then rm -f "$tmp"; return 1; fi
  if cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 0; fi
  mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# _clock_real_claude — 0 when some `claude` on PATH is not our wrapper.
_clock_real_claude() {
  local d c self
  self="$(readlink -f "$SB_CLAUDE_WRAPPER" 2>/dev/null)"
  local IFS=:
  for d in $PATH; do
    c="${d:-.}/claude"
    [ -f "$c" ] && [ -x "$c" ] || continue
    [ -n "$self" ] && [ "$(readlink -f "$c")" = "$self" ] && continue
    return 0
  done
  return 1
}

if ! [[ "$SB_CLAUDE_SHIM" =~ $SB_CLAUDE_PATH_RE ]] || [ "${SB_CLAUDE_SHIM##*/}" != claude-clock-24h.js ] \
   || ! [[ "$SB_CLAUDE_WRAPPER" =~ $SB_CLAUDE_PATH_RE ]] || [ "${SB_CLAUDE_WRAPPER##*/}" != claude ]; then
  log "WARN: unsafe SB_CLAUDE_SHIM / SB_CLAUDE_WRAPPER — Claude Code reset times stay 12h"
elif [ -e "$SB_CLAUDE_WRAPPER" ] && ! _clock_ours "$SB_CLAUDE_WRAPPER"; then
  log "WARN: ${SB_CLAUDE_WRAPPER} exists and is not ours — Claude Code reset times stay 12h"
elif ! _clock_real_claude; then
  if [ -e "$SB_CLAUDE_WRAPPER" ]; then
    rm -f "$SB_CLAUDE_WRAPPER" 2>/dev/null && log "no Claude Code installed — reset-time wrapper removed" \
      || log "WARN: could not remove ${SB_CLAUDE_WRAPPER} (no Claude Code behind it)"
  else
    log "no Claude Code installed — reset-time shim not installed"
  fi
elif mkdir -p "$(dirname "$SB_CLAUDE_SHIM")" 2>/dev/null && _clock_put "$SB_CLAUDE_SHIM" 0644 <<'SBCLOCKSHIM'
// Installed by agent-runners base/09b-clock.sh (DEV-284); a refresh rewrites it.
// Preloaded into Claude Code by /usr/local/bin/claude (BUN_OPTIONS=--preload).
// Claude Code formats every usage-limit / reset time with toLocaleString or
// toLocaleTimeString("en-US", {hour12: true}) and reads no setting there. While
// settings.json has timeFormat 24-hour, that call shape gets the turn footer's h23
// clock instead: "Oct 10, 2am" -> "Oct 10, 02:00", "1:20pm" -> "13:20". Any other
// call passes through. A throw here would stop claude from starting, so any
// surprise leaves Claude Code as shipped.
(() => {
  try {
    const env = process.env;
    if (env.BUN_OPTIONS) {
      const rest = env.BUN_OPTIONS.split(/\s+/)
        .filter((a) => a && !/^--preload=\S*\/claude-clock-24h\.js$/.test(a)).join(" ");
      if (rest) env.BUN_OPTIONS = rest; else delete env.BUN_OPTIONS;
    }
    if (!/\/claude(\.exe)?$/.test(process.execPath || "")) return;
    const path = require("path");
    const dir = env.CLAUDE_CONFIG_DIR || path.join(require("os").homedir(), ".claude");
    const tf = JSON.parse(require("fs").readFileSync(path.join(dir, "settings.json"), "utf8")).timeFormat;
    if (tf !== "24-hour" && tf !== "24-hour-utc") return;
    for (const name of ["toLocaleString", "toLocaleTimeString"]) {
      const orig = Date.prototype[name];
      if (typeof orig !== "function") continue;
      Date.prototype[name] = function (locales, options) {
        if (locales === "en-US" && options && options.hour12 === true && options.hour !== undefined) {
          const o = { ...options, hourCycle: "h23", hour: "2-digit", minute: options.minute || "2-digit" };
          delete o.hour12;
          try { return orig.call(this, locales, o); } catch {}
        }
        return orig.apply(this, arguments);
      };
    }
  } catch {}
})();
SBCLOCKSHIM
then
  if sed "s|@SB_CLAUDE_SHIM@|${SB_CLAUDE_SHIM}|; s|@SB_CLAUDE_MARK@|${SB_CLAUDE_MARK}|" <<'SBCLOCKWRAP' | _clock_put "$SB_CLAUDE_WRAPPER" 0755
#!/bin/bash
# @SB_CLAUDE_MARK@ (DEV-284) — installed by agent-runners base/09b-clock.sh; a refresh
# rewrites it. Runs the real Claude Code (the next `claude` on PATH) with the
# 24h reset-time shim preloaded; without a readable shim it is a plain exec.
shim="@SB_CLAUDE_SHIM@"
self="$(readlink -f "$0")"
IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do
  c="${d:-.}/claude"
  [ -f "$c" ] && [ -x "$c" ] || continue
  [ "$(readlink -f "$c")" = "$self" ] && continue
  [ -r "$shim" ] && export BUN_OPTIONS="--preload=${shim}${BUN_OPTIONS:+ $BUN_OPTIONS}"
  exec -a claude "$c" "$@"
done
echo "claude: Claude Code is not installed (only ${self} is on PATH)" >&2
exit 127
SBCLOCKWRAP
  then
    log "Claude Code reset times: 24h shim at ${SB_CLAUDE_SHIM}, wrapper at ${SB_CLAUDE_WRAPPER}"
  else
    log "WARN: could not write ${SB_CLAUDE_WRAPPER} — Claude Code reset times stay 12h"
  fi
else
  log "WARN: could not write ${SB_CLAUDE_SHIM} — Claude Code reset times stay 12h"
fi
