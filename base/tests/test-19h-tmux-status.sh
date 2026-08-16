#!/usr/bin/env bash
# base/tests/test-19h-tmux-status.sh — regression guard for the tmux status line
# (base/19h-tmux-status.sh + the embedded /usr/local/bin/sb-tmux-status helper).
#
# Contract under test:
#   * the step stays syntactically valid, writes BOTH artifacts inline
#     (/etc/tmux.conf + sb-tmux-status), is listed in refresh-manifest.txt and
#     sourced by run.sh — so it reaches new provisions AND the live fleet;
#   * the helper shows job fields ONLY for the session job-context.json belongs
#     to (`sbjob-<session_id>` match) — a concurrent/lingering session must
#     fall back to the agent identity, never wear another job's ticket;
#   * every degradation (no ticket_key, no role, unusable jq, no job-context,
#     no .agent-env) stays graceful: identity or bare-brand output, exit 0,
#     never a dangling separator.
#
# Pure bash + sed/tr/cut; jq is STUBBED on PATH (same idiom as pgrep/xdotool in
# test-19c-terminal-capture.sh) so the test runs on hosts without jq. The stub
# answers exactly the helper's `jq -r '.<field> // empty' <file>` calls against
# the one-field-per-line JSON the orchestrator writes (JSON.stringify null,2).
# Run: bash base/tests/test-19h-tmux-status.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
STEP="$BASE/19h-tmux-status.sh"
SID="11111111-2222-3333-4444-555555555555"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# ── 0. step validity + wiring ────────────────────────────────────────────────
bash -n "$STEP" && ok "bash -n: 19h-tmux-status.sh" || bad "bash -n failed on the step"
grep -qF '/etc/tmux.conf' "$STEP" && ok "step writes /etc/tmux.conf" || bad "/etc/tmux.conf write missing"
grep -qF '/usr/local/bin/sb-tmux-status' "$STEP" && ok "step installs sb-tmux-status" || bad "sb-tmux-status install missing"
grep -qF 'status-interval' "$STEP" && ok "conf sets status-interval" || bad "status-interval missing from the conf"
grep -qF "sb-tmux-status '#{session_name}'" "$STEP" && ok "status-left hands #{session_name} to the helper" || bad "session_name plumbing missing from status-left"
grep -qF 'pane_title' "$STEP" && ok "status-right keeps the Claude pane title" || bad "pane_title missing from status-right"
grep -qF '19h-tmux-status.sh' "$BASE/refresh-manifest.txt" && ok "listed in refresh-manifest.txt (fleet refresh)" || bad "not listed in refresh-manifest.txt"
grep -qF '19h-tmux-status.sh' "$BASE/run.sh" && ok "sourced by run.sh (new provisions)" || bad "not sourced by run.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── extract the embedded helper (between the SBSTATUSEOF heredoc markers) ────
HELPER="$TMP/sb-tmux-status"
sed -n '/SBSTATUSEOF/,/^SBSTATUSEOF$/p' "$STEP" | sed '1d;$d' > "$HELPER"
chmod +x "$HELPER"
head -1 "$HELPER" | grep -q bash && ok "extracted the sb-tmux-status helper from the heredoc" || bad "helper extraction failed"
bash -n "$HELPER" && ok "bash -n: sb-tmux-status" || bad "bash -n failed on the helper"

# ── stubs on PATH ────────────────────────────────────────────────────────────
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/jq" <<'EOF'
#!/usr/bin/env bash
# stub jq: handles `jq -r '.<field> // empty' <file>` over pretty-printed
# one-field-per-line JSON (string or number values); missing field → nothing.
filter="$2"; file="$3"
field="${filter#.}"; field="${field%% *}"
[ -f "$file" ] || exit 2
sed -n "s/^ *\"$field\": *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "$file"
EOF
chmod +x "$BIN/jq"

run_status() { HOME="$1" PATH="$BIN:$PATH" "$HELPER" "${2-}"; }
strip_styles() { sed 's/#\[[^]]*\]//g'; }

mk_ctx() {  # $1 = HOME dir; stdin = job-context.json body
  mkdir -p "$1/.sidebutton"; cat > "$1/.sidebutton/job-context.json"
}
mk_env() {  # $1 = HOME dir
  mkdir -p "$1"; printf 'AGENT_NAME=euler\nAGENT_ROLE=sd\n' > "$1/.agent-env"
}

# ── 1. matching session with the full portal payload → role · ticket · job ───
H1="$TMP/h1"; mk_env "$H1"
mk_ctx "$H1" <<EOF
{
  "job_id": 17083,
  "step_index": 0,
  "workflow_id": "agent_sd_coverage",
  "ticket_key": "SCRUM-1969",
  "started_at": "2026-08-16T09:00:00.000Z",
  "session_id": "$SID",
  "role": "sd",
  "role_label": "Skill Discovery"
}
EOF
out="$(run_status "$H1" "sbjob-$SID" | strip_styles)"
case "$out" in
  *"Skill Discovery"*"SCRUM-1969"*"job 17083"*) ok "matching session shows role label · ticket · job id ($out)" ;;
  *) bad "matching session wrong: '$out'" ;;
esac

# ── 2. session MISMATCH → agent identity, never the other job's ticket ───────
out="$(run_status "$H1" "sbjob-99999999-aaaa-bbbb-cccc-dddddddddddd" | strip_styles)"
case "$out" in *SCRUM-1969*|*17083*) bad "mismatched session leaked job fields: '$out'" ;; *euler*) ok "mismatched session falls back to the agent identity ($out)" ;; *) bad "mismatched session fallback wrong: '$out'" ;; esac

# ── 3. no ticket_key / no role in context → role from .agent-env, no dangle ──
H3="$TMP/h3"; mk_env "$H3"
mk_ctx "$H3" <<EOF
{
  "job_id": 17090,
  "step_index": 0,
  "workflow_id": "agent_qa_validate",
  "session_id": "$SID"
}
EOF
out="$(run_status "$H3" "sbjob-$SID" | strip_styles)"
case "$out" in *SCRUM*) bad "ticketless run invented a ticket: '$out'" ;; *"SD"*"job 17090") ok "ticketless run shows env role + job id, ends clean ($out)" ;; *) bad "ticketless run wrong: '$out'" ;; esac

# ── 4. unusable jq (present but failing) → identity fallback ─────────────────
BROKEN="$TMP/broken"; mkdir -p "$BROKEN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BROKEN/jq"; chmod +x "$BROKEN/jq"
out="$(HOME="$H1" PATH="$BROKEN:$PATH" "$HELPER" "sbjob-$SID" | strip_styles)"
case "$out" in *17083*|*SCRUM*) bad "broken jq still produced job fields: '$out'" ;; *euler*) ok "unusable jq degrades to the agent identity ($out)" ;; *) bad "unusable jq fallback wrong: '$out'" ;; esac

# ── 5. no job-context at all → identity from .agent-env ──────────────────────
H5="$TMP/h5"; mk_env "$H5"
out="$(run_status "$H5" "sbjob-$SID" | strip_styles)"
case "$out" in *euler*sd*) ok "idle agent shows name · role ($out)" ;; *) bad "idle identity wrong: '$out'" ;; esac

# ── 6. nothing on disk → bare brand, still exit 0 ────────────────────────────
H6="$TMP/h6"; mkdir -p "$H6"
if out="$(run_status "$H6" "" | strip_styles)"; then
  case "$out" in *"[sb]"*) ok "empty box still prints the [sb] brand and exits 0 ($out)" ;; *) bad "empty-box output wrong: '$out'" ;; esac
else
  bad "helper exited non-zero on an empty box"
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
