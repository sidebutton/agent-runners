#!/usr/bin/env bash
# base/tests/test-19c-terminal-capture.sh — regression guard for the SCRUM-1414
# window-scoped terminal capture in base/assets/report-health-snapshot.sh.
#
# The reporter must crop the FOCUSED Claude Code window for the active session and
# add it to the /api/agents/health-report payload as terminal_b64 (+ session_id),
# keyed by the session — WITHOUT ever regressing the desktop frame or the POST. The
# session id is resolved from ~/.sidebutton/job-context.json (fallback: the running
# `claude --session-id <uuid>` whose transcript is newest, mirroring base/19e); the
# window is found via the tmux `sbjob-<session_id>` carried in the xfce4-terminal
# argv — NOT the title, which recon showed is non-unique across concurrent sessions.
# Every hop degrades to "omit the terminal frame" (no xdotool / no session / no
# window / empty file) while metrics + the desktop screenshot still post.
#
# Pure bash; the payload-shape assertions also need jq + python3 (present on CI; a
# jq-less local run still proves the capture path + runs bash -n). The test never
# touches X or real processes — xdotool/import/pgrep/ps are stubbed on PATH.
# Run: bash base/tests/test-19c-terminal-capture.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
REPORTER="$BASE/assets/report-health-snapshot.sh"
SID="11111111-2222-3333-4444-555555555555"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }
skip() { printf 'skip - %s\n' "$1"; }

# ── 0. the reporter must stay syntactically valid + carry the change ─────────────
bash -n "$REPORTER" && ok "bash -n: report-health-snapshot.sh" || bad "bash -n failed on the reporter"
grep -qF 'resolve_active_session()'  "$REPORTER" && ok "resolve_active_session() present"   || bad "resolve_active_session() missing"
grep -qF 'capture_terminal_window()' "$REPORTER" && ok "capture_terminal_window() present"  || bad "capture_terminal_window() missing"
grep -qF 'terminal_b64'              "$REPORTER" && ok "payload builder emits terminal_b64" || bad "terminal_b64 missing from the payload builder"
grep -qF '"session_id"'              "$REPORTER" && ok "payload builder emits session_id"   || bad "session_id missing from the payload builder"
grep -qF 'sbjob-'                    "$REPORTER" && ok "window mapping keys on sbjob-<session_id>" || bad "sbjob-<session_id> mapping missing"
grep -qF '${DISPLAY:=:10}'           "$REPORTER" && ok "DISPLAY defaulted for the cron/manual path"  || bad "DISPLAY default missing"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── stubs on PATH (no real X / processes) ────────────────────────────────────────
BIN="$TMP/bin"; mkdir -p "$BIN"
# pgrep: any sbjob-* lookup → our fake terminal pid; everything else (e.g. -x claude) → none.
cat > "$BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in sbjob-*) echo 4242; exit 0;; esac; done
exit 0
EOF
# ps: comm of the fake pid is xfce4-terminal (so the loop selects it as the terminal).
cat > "$BIN/ps" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-o comm="*) echo "xfce4-terminal";;
  *"-o args="*) echo "claude --session-id 11111111-2222-3333-4444-555555555555 -p task";;
esac
exit 0
EOF
# xdotool: `search --pid <pid>` → a window id.
cat > "$BIN/xdotool" <<'EOF'
#!/usr/bin/env bash
case "$*" in *search*) echo 8675309;; esac
exit 0
EOF
# import: write a non-empty fake PNG to the png:<path> target.
cat > "$BIN/import" <<'EOF'
#!/usr/bin/env bash
out=""; for a in "$@"; do case "$a" in png:*) out="${a#png:}";; esac; done
[ -n "$out" ] && printf '\x89PNG\r\n\x1a\nFAKE' > "$out"
exit 0
EOF
chmod +x "$BIN"/*

# Extract the two helpers from the reporter and source them in isolation (mirrors
# test-14-git-capture.sh: each function's only column-0 `}` is its own closer).
awk '/^resolve_active_session\(\) \{/{p=1} p{print} p&&/^\}/{exit}'  "$REPORTER" >  "$TMP/funcs.sh"
awk '/^capture_terminal_window\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$REPORTER" >> "$TMP/funcs.sh"
grep -q '^capture_terminal_window() {' "$TMP/funcs.sh" \
  && ok "extracted resolve_active_session + capture_terminal_window from the reporter" \
  || bad "could not extract the helpers from the reporter heredoc"
# shellcheck source=/dev/null
. "$TMP/funcs.sh"

# ── 1. capture_terminal_window: happy path writes a frame (all stubs resolve) ────
OUT="$TMP/terminal.png"; rm -f "$OUT"
if ( PATH="$BIN:$PATH"; capture_terminal_window "$SID" "$OUT" ) && [ -s "$OUT" ]; then
  ok "capture_terminal_window writes a frame when session→window resolves"
else
  bad "capture_terminal_window failed to write a frame on the happy path"
fi

# ── 2. graceful skip: no xdotool on PATH → non-zero, no file written ──────────────
# PATH limited to the stub dir (no xdotool, no system xdotool): the function must
# bail at its `command -v xdotool` guard before any capture.
rm -f "$OUT"
NOX="$TMP/nox"; mkdir -p "$NOX"; cp "$BIN/pgrep" "$BIN/ps" "$BIN/import" "$NOX/"; chmod +x "$NOX"/*
if ( PATH="$NOX"; capture_terminal_window "$SID" "$OUT" ); then
  bad "capture_terminal_window must return non-zero when xdotool is absent"
elif [ -s "$OUT" ]; then
  bad "capture wrote a frame despite xdotool being absent"
else
  ok "no xdotool → capture returns non-zero and writes no frame (graceful skip)"
fi

# ── 3. graceful skip: no window found (xdotool returns nothing) → non-zero ────────
rm -f "$OUT"
NOWIN="$TMP/nowin"; mkdir -p "$NOWIN"; cp "$BIN/pgrep" "$BIN/ps" "$BIN/import" "$NOWIN/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NOWIN/xdotool"   # search prints nothing
chmod +x "$NOWIN"/*
if ( PATH="$NOWIN:$PATH"; capture_terminal_window "$SID" "$OUT" ); then
  bad "capture_terminal_window must return non-zero when no window id resolves"
else
  ok "no window id → capture returns non-zero (graceful skip)"
fi

# ── 4. empty session id → no-op ──────────────────────────────────────────────────
rm -f "$OUT"
if ( PATH="$BIN:$PATH"; capture_terminal_window "" "$OUT" ); then
  bad "capture_terminal_window must return non-zero on an empty session id"
else
  ok "empty session id → capture returns non-zero (no key to map on)"
fi

# ── 5. resolve_active_session: job-context.json is the primary source ────────────
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$TMP/home/.sidebutton"
  printf '{"session_id":"%s"}' "$SID" > "$TMP/home/.sidebutton/job-context.json"
  got="$( HOME="$TMP/home" resolve_active_session )"
  [ "$got" = "$SID" ] && ok "resolve_active_session reads .session_id from job-context.json" \
    || bad "resolve_active_session returned '$got' (expected the job-context session_id)"
  # Nothing to resolve (no job-context, no claude procs) → empty, no crash.
  got2="$( HOME="$TMP/empty" PATH="$BIN:$PATH" resolve_active_session )"
  [ -z "$got2" ] && ok "resolve_active_session is empty when nothing resolves (graceful)" \
    || bad "resolve_active_session returned '$got2' when it should be empty"
else
  skip "jq not installed — skipping resolve_active_session job-context assertions"
fi

# ── 6. payload builder: terminal_b64 + session_id present when captured; and the
#       fallback OMITS both while keeping the desktop frame + metrics (zero regression).
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  awk "/^python3 - << 'PYEOF'\$/{f=1;next} /^PYEOF\$/{f=0} f" "$REPORTER" > "$TMP/build.py"
  [ -s "$TMP/build.py" ] && ok "extracted the python payload builder" || bad "could not extract the payload builder"

  SSPNG="$TMP/ss.png";   printf '\x89PNG\r\n\x1a\nDESK' > "$SSPNG"
  TPNG="$TMP/term.png";  printf '\x89PNG\r\n\x1a\nTERM' > "$TPNG"

  # 6a. captured frame + resolved session.
  P1="$TMP/p1.json"
  env -i PATH="$PATH" HOME="$TMP/home" \
    SS_FILE="$SSPNG" TERM_FILE="$TPNG" SESSION_ID="$SID" PAYLOAD_FILE="$P1" \
    python3 "$TMP/build.py"
  [ "$(jq -r 'has("terminal_b64")' "$P1")" = "true" ] && ok "payload carries terminal_b64 when a frame was captured" || bad "terminal_b64 absent despite a captured frame"
  [ "$(jq -r '.session_id' "$P1")" = "$SID" ]         && ok "payload carries the active session_id"                || bad "session_id missing/wrong in the payload"
  [ "$(jq -r 'has("screenshot_b64")' "$P1")" = "true" ] && ok "desktop screenshot_b64 still present (no regression)" || bad "screenshot_b64 regressed"
  [ "$(jq -r '.metrics | has("cpu_pct")' "$P1")" = "true" ] && ok "metrics block still present" || bad "metrics regressed"

  # 6b. fallback — no frame (missing file) + unresolved session (empty).
  P2="$TMP/p2.json"
  env -i PATH="$PATH" HOME="$TMP/home" \
    SS_FILE="$SSPNG" TERM_FILE="$TMP/none.png" SESSION_ID="" PAYLOAD_FILE="$P2" \
    python3 "$TMP/build.py"
  [ "$(jq -r 'has("terminal_b64")' "$P2")" = "false" ] && ok "fallback omits terminal_b64 when no frame captured" || bad "terminal_b64 present in the fallback (must be omitted)"
  [ "$(jq -r 'has("session_id")'  "$P2")" = "false" ] && ok "fallback omits session_id when unresolved"          || bad "session_id present despite being unresolved"
  [ "$(jq -r 'has("screenshot_b64")' "$P2")" = "true" ] && ok "fallback still posts the desktop screenshot_b64" || bad "fallback dropped screenshot_b64"
  [ "$(jq -r '.metrics | has("cpu_pct")' "$P2")" = "true" ] && ok "fallback still includes metrics" || bad "fallback dropped metrics"
else
  skip "jq/python3 not installed — skipping payload-shape assertions (bash -n + capture path still ran)"
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
