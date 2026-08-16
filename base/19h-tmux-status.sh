# 19h-tmux-status.sh — tmux status line with the portal job identity (role,
# ticket key, portal job id) on agent VMs.
#
# WHY: a dispatched job runs Claude Code inside `tmux new-session -s
# sbjob-<claude-session-uuid>` in an xfce4-terminal (launched by the sidebutton
# server's terminal.open step — see the contract note in
# assets/report-health-snapshot.sh). tmux is installed by base/02 and was never
# configured, so the stock status bar showed `[sbjob-d30` — the session UUID
# chopped at the default 10-column status-left, mashed into the window index.
# An operator watching the desktop (VNC/RDP or the portal's terminal capture)
# could not tell which job or ticket a terminal belonged to. The metadata a
# human wants is already on the box: the Temporal orchestrator writes
# ~/.sidebutton/job-context.json (job_id, ticket_key, session_id — and role /
# role_label once the portal ships them) before every step, and ~/.agent-env
# carries the provision identity (AGENT_NAME / AGENT_ROLE).
#
# WHAT: /etc/tmux.conf (system-wide; nothing else ships one, and it leaves
# ~/.tmux.conf free for operators) points status-left at
# /usr/local/bin/sb-tmux-status. The helper shows the job fields ONLY when the
# session being painted is the one job-context.json belongs to
# (`sbjob-<session_id>` match) — job-context is a single global file, so a
# lingering or concurrent session must never wear another job's ticket (same
# rule as the 19c terminal capture, which keys on the session id and never the
# title). Anything else degrades to the agent identity. status-right keeps
# Claude Code's live pane title — its OSC title escapes are the best "what is
# it doing right now" signal — just wider than the stock 21 columns.
#
# Refresh-safe (listed in refresh-manifest.txt): two idempotent root file
# writes, no apt, no component gates, no services touched. A running tmux
# server keeps its old config until it exits; job sessions are per-job, so the
# next dispatch after a refresh picks the bar up.

step "Step 19h/16: tmux status line (portal job identity)"

cat > /usr/local/bin/sb-tmux-status <<'SBSTATUSEOF'
#!/usr/bin/env bash
# sb-tmux-status — SideButton status-left segment for the agent VM's tmux bar.
# Installed by agent-runners base/19h-tmux-status.sh; invoked from
# /etc/tmux.conf as `#(sb-tmux-status '#{session_name}')` every status-interval.
#
# tmux expands #{session_name} before running the #() command, so the helper
# knows WHICH session's bar it is painting. Job fields come from
# ~/.sidebutton/job-context.json and are shown ONLY when that file's session_id
# matches this session (`sbjob-<session_id>`): job-context is one global file,
# so a lingering/concurrent session must never wear another job's ticket.
# Every miss (no file, unusable jq, other session, context cleared after the
# step) degrades to the provision identity from ~/.agent-env, then to the bare
# [sb] brand. Always exits 0 — a broken segment must never garble the bar.
set -u
SESSION="${1:-}"
CTX="$HOME/.sidebutton/job-context.json"
AGENT_ENV="$HOME/.agent-env"
BRAND="#[fg=colour45,bold][sb]#[default]"
SEP=" #[fg=colour241]·#[default] "

# Values land inside a tmux format string: strip the characters that would open
# a style/format sequence there (#, [, ], \) plus stray quotes, and cap the
# width so one long label cannot push the window list off the bar.
scrub() { printf '%s' "${1:-}" | tr -d '#[]\\"' | cut -c1-28; }
ctx() { jq -r ".$1 // empty" "$CTX" 2>/dev/null; }
agent_env() { [ -f "$AGENT_ENV" ] && sed -n "s/^$1=//p" "$AGENT_ENV" 2>/dev/null | tail -1; }

job_segment() {
  [ -n "$SESSION" ] && [ -f "$CTX" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local sid job ticket role out
  sid="$(ctx session_id)"
  [ -n "$sid" ] && [ "$SESSION" = "sbjob-${sid}" ] || return 1
  job="$(scrub "$(ctx job_id)")"
  [ -n "$job" ] || return 1
  # Human label when the portal sends one; else the job's role slug uppercased;
  # else the provision-time agent role — so the bar shows a role today even
  # before the portal starts writing role/role_label into job-context.
  role="$(scrub "$(ctx role_label)")"
  if [ -z "$role" ]; then
    role="$(scrub "$(ctx role)")"
    [ -n "$role" ] || role="$(scrub "$(agent_env AGENT_ROLE)")"
    role="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
  fi
  ticket="$(scrub "$(ctx ticket_key)")"
  out=""
  [ -n "$role" ]   && out="#[fg=colour114,bold]${role}#[default]"
  [ -n "$ticket" ] && out="${out:+${out}${SEP}}#[fg=colour221]${ticket}#[default]"
  out="${out:+${out}${SEP}}#[fg=colour250]job ${job}#[default]"
  printf '%s %s' "$BRAND" "$out"
}

identity_segment() {
  local name role out=""
  name="$(scrub "$(agent_env AGENT_NAME)")"
  role="$(scrub "$(agent_env AGENT_ROLE)")"
  [ -n "$name" ] && out="#[fg=colour250]${name}#[default]"
  [ -n "$role" ] && out="${out:+${out}${SEP}}#[fg=colour245]${role}#[default]"
  printf '%s%s' "$BRAND" "${out:+ ${out}}"
}

job_segment || identity_segment
exit 0
SBSTATUSEOF
chmod 0755 /usr/local/bin/sb-tmux-status
log "sb-tmux-status helper installed"

# System-wide config: read at tmux SERVER start, so it applies from the next
# job session after provision/refresh. Everything not set here stays stock.
cat > /etc/tmux.conf <<'TMUXCONFEOF'
# /etc/tmux.conf — SideButton agent status line.
# Installed by agent-runners base/19h-tmux-status.sh (refresh-manifest step);
# edit THERE, not here — a fleet refresh overwrites this file.
# status-left: portal job identity (role · ticket · job id) via sb-tmux-status,
# scoped to the session job-context.json belongs to (see the helper).
# status-right: Claude Code's live pane title (stock behaviour, widened) + clock.
set -g status-interval 5
set -g status-left-length 60
set -g status-right-length 48
set -g status-style "bg=colour235,fg=colour250"
set -g window-status-current-style "fg=colour255,bold"
set -g status-left "#(/usr/local/bin/sb-tmux-status '#{session_name}') "
set -g status-right "#[fg=colour245]#{=32:pane_title}#[default]  %H:%M "
TMUXCONFEOF
log "/etc/tmux.conf installed (status bar wired to sb-tmux-status)"
