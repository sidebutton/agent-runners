#!/usr/bin/env bash
# base/tests/test-03b-glab-cli.sh — regression guard for the GitLab CLI base step
# (base/03b-glab-cli.sh, SCRUM-1958).
#
# Contract under test:
#   * WIRING — sourced by run.sh exactly once, AFTER 03-gh-cli.sh and BEFORE
#     04-desktop.sh, and UNGATED (no component / SKIP_* / INSTALL_* flag: glab is
#     unconditional on every agent, exactly like gh). Deliberately NOT in
#     refresh-manifest.txt — install steps 01..13 are policy-excluded from the
#     live-agent refresh path.
#   * INSTALL ONLY — no `auth login`, no credential helper, no GITLAB_TOKEN read
#     anywhere in the step: a fresh image must carry glab with NO GitLab
#     connection configured. Auth is a separate story (SCRUM-1952), gated on
#     GITLAB_TOKEN at boot; baking it here would put a credential in the image.
#   * BEHAVIOUR — the step is EXECUTED against stubbed curl/apt-get/dpkg/sha256sum:
#     idempotent skip when glab is present, correct per-arch asset + checksum,
#     install ONLY after the checksum matches, and a loud die with NO install on a
#     mismatch or an unpinned architecture.
#
# Hermetic: no network, no root, nothing installed, nothing written outside the
# sandbox. The behaviour cases run with PATH set to the stub dir ALONE (plus
# symlinks to the coreutils the step calls), so `command -v glab` is decided by
# the sandbox and never by the host — the suite stays green on a provisioned agent
# that legitimately has a real glab installed — and with TMPDIR pointed into the
# sandbox, so the step's download dir never touches the host's real /tmp (where a
# root-owned leftover from an aborted provision would otherwise false-fail it).
# Stub-on-PATH idiom borrowed from the jq stub in test-19h-tmux-status.sh.
# Run: bash base/tests/test-03b-glab-cli.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
STEP="$BASE/03b-glab-cli.sh"
RUNSH="$BASE/run.sh"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# ── 0. step validity ─────────────────────────────────────────────────────────
[ -f "$STEP" ] && ok "base/03b-glab-cli.sh exists" || { bad "step missing: $STEP"; exit 1; }
bash -n "$STEP" && ok "bash -n: 03b-glab-cli.sh" || bad "bash -n failed on the step"

# ── 1. wiring into run.sh: once, ungated, between 03 and 04 ──────────────────
n_src="$(grep -c '03b-glab-cli\.sh' "$RUNSH")"
[ "$n_src" = "1" ] && ok "run.sh sources 03b exactly once" || bad "run.sh sources 03b $n_src times (want 1)"

l_03="$(grep -n '^\. "\$BASE_DIR/03-gh-cli\.sh"'   "$RUNSH" | cut -d: -f1)"
l_03b="$(grep -n '^\. "\$BASE_DIR/03b-glab-cli\.sh"' "$RUNSH" | cut -d: -f1)"
l_04="$(grep -n '^\. "\$BASE_DIR/04-desktop\.sh"'  "$RUNSH" | cut -d: -f1)"
if [ -n "$l_03b" ]; then
  ok "03b is sourced at top level of run.sh (column 0 ⇒ not nested in a gate)"
else
  bad "no top-level '. \"\$BASE_DIR/03b-glab-cli.sh\"' line in run.sh (missing or indented ⇒ gated)"
fi
if [ -n "$l_03" ] && [ -n "$l_03b" ] && [ -n "$l_04" ] && [ "$l_03" -lt "$l_03b" ] && [ "$l_03b" -lt "$l_04" ]; then
  ok "order: 03-gh-cli ($l_03) → 03b-glab-cli ($l_03b) → 04-desktop ($l_04)"
else
  bad "03b is not sequenced between 03-gh-cli and 04-desktop (03=$l_03 03b=$l_03b 04=$l_04)"
fi

# Ungated by construction: the step must not read any component/skip gate itself.
# Comments stripped first, same as the install-only scan below: the header
# DOCUMENTS that it carries no SKIP_*/INSTALL_* gate, so scanning raw bytes would
# fire on a prose edit that spells one of those names out (zero behaviour change).
if sed 's/#.*//' "$STEP" | grep -qE 'has_component|SKIP_[A-Z_]+|INSTALL_[A-Z_]+'; then
  bad "step reads a component/SKIP_/INSTALL_ gate — glab must be unconditional"
else
  ok "step reads no component/SKIP_/INSTALL_ gate (unconditional, like gh)"
fi

# ── 2. refresh-manifest exclusion (install-range policy) ─────────────────────
if grep -qE '^[[:space:]]*03b-glab-cli\.sh' "$BASE/refresh-manifest.txt"; then
  bad "03b listed in refresh-manifest.txt — install steps 01..13 are refresh-excluded"
else
  ok "not listed in refresh-manifest.txt (install-range exclusion honoured)"
fi

# ── 3. install-only: no auth, no credential helper, no token read ────────────
# Comments are stripped first — the step's header DOCUMENTS what it must not do
# (auth login, credential helper, GITLAB_TOKEN), so scan the code, not the prose.
if sed 's/#.*//' "$STEP" | grep -qiE 'auth[[:space:]]+login|credential[.-]?helper|GITLAB_TOKEN|glab auth'; then
  bad "step touches auth/credentials — install-only (auth is SCRUM-1952, boot-gated)"
else
  ok "install-only: no auth login / credential helper / GITLAB_TOKEN in the step"
fi

# ── 4. pins are well-formed and per-arch distinct ────────────────────────────
VER="$(sed -n 's/^GLAB_VERSION="\([^"]*\)"$/\1/p' "$STEP")"
SHA_AMD64="$(sed -n 's/^GLAB_SHA256_AMD64="\([0-9a-f]\{64\}\)"$/\1/p' "$STEP")"
SHA_ARM64="$(sed -n 's/^GLAB_SHA256_ARM64="\([0-9a-f]\{64\}\)"$/\1/p' "$STEP")"
[ -n "$VER" ] && ok "GLAB_VERSION pinned ($VER)" || bad "GLAB_VERSION missing / not a bare literal"
[ -n "$SHA_AMD64" ] && ok "amd64 sha256 pinned (64 hex)" || bad "GLAB_SHA256_AMD64 missing or malformed"
[ -n "$SHA_ARM64" ] && ok "arm64 sha256 pinned (64 hex)" || bad "GLAB_SHA256_ARM64 missing or malformed"
[ -n "$SHA_AMD64" ] && [ "$SHA_AMD64" != "$SHA_ARM64" ] \
  && ok "per-arch checksums differ" || bad "amd64/arm64 checksums identical — one arch is mispinned"

# The download must be bounded in ABSOLUTE time, not just per attempt. curl's
# --max-time applies to each attempt, so --max-time N --retry R alone allows
# ~(R+1)*N of blocked provisioning; --retry-max-time is what caps the operation.
# Comments stripped: the rationale above the curl call names the flag, so a raw
# grep would pass on the prose alone even if the flag were dropped from the code.
if sed 's/#.*//' "$STEP" | grep -q -- '--retry-max-time'; then
  ok "download is bounded by --retry-max-time (retries cannot multiply --max-time)"
else
  bad "no --retry-max-time: --max-time is per-attempt, so --retry can multiply it into a provisioning hang"
fi

# ── sandbox: stubs for every external the step calls ─────────────────────────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; STUB_LOG="$TMP/log"; DL="$TMP/dl"; mkdir -p "$BIN" "$STUB_LOG" "$DL"
export BIN STUB_LOG

# Real utilities the step (cut/rm/head) and the stubs themselves (bash for the
# `#!/usr/bin/env bash` shebang, cat/chmod to fabricate the "installed" glab)
# need, symlinked in so PATH can be the stub dir ALONE.
for u in cut rm head sed bash cat chmod mktemp; do
  p="$(command -v "$u")" && ln -sf "$p" "$BIN/$u" || { bad "missing coreutil for sandbox: $u"; exit 1; }
done

cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
# stub curl: record argv, write placeholder bytes to the -o target.
printf '%s\n' "$*" >> "$STUB_LOG/curl.args"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf 'stub-deb-bytes\n' > "$out"
EOF

cat > "$BIN/dpkg" <<'EOF'
#!/usr/bin/env bash
# stub dpkg: only --print-architecture is used by the step.
[ "${1:-}" = "--print-architecture" ] && printf '%s\n' "$STUB_ARCH"
EOF

cat > "$BIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
# stub sha256sum: answer with the test-controlled digest for the given file.
printf '%s  %s\n' "$STUB_SHA" "${1:-}"
EOF

cat > "$BIN/apt-get" <<'EOF'
#!/usr/bin/env bash
# stub apt-get: record argv and simulate the install by putting glab on PATH.
printf '%s\n' "$*" >> "$STUB_LOG/apt.args"
cat > "$BIN/glab" <<'INNER'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && printf 'glab %s (stub)\n' "${STUB_GLAB_VERSION:-0.0.0}"
INNER
chmod +x "$BIN/glab"
EOF
chmod +x "$BIN"/curl "$BIN"/dpkg "$BIN"/sha256sum "$BIN"/apt-get

# Run the step in an isolated subshell with the lib.sh helpers stubbed.
# Echoes the step's combined output; the caller reads $? for die/no-die.
run_step() { # $1 = STUB_ARCH, $2 = STUB_SHA
  rm -f "$STUB_LOG"/*.args
  rm -rf "$DL"; mkdir -p "$DL"
  (
    # run.sh:15 is `set -euo pipefail` and SOURCES the step, so -e must be on
    # here too: without it a command that fails mid-step keeps going in the
    # sandbox while it would abort a real provision, and the guard reads green.
    set -euo pipefail
    # TMPDIR is what makes this hermetic — the step's `mktemp -d` lands inside
    # the sandbox instead of the host's real /tmp.
    export PATH="$BIN" TMPDIR="$DL" STUB_ARCH="$1" STUB_SHA="$2" STUB_GLAB_VERSION="$VER"
    # The real array from 01-preflight.sh:51, not a shortened stand-in, so the
    # recorded apt argv pins that the step passes the dpkg conf-old options through.
    # shellcheck disable=SC2034  # read by the sourced step, not by this file
    APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    log()  { printf '%s\n' "$*"; }
    step() { printf '== %s\n' "$*"; }
    die()  { printf 'DIE: %s\n' "$*"; exit 1; }
    # shellcheck disable=SC1090
    . "$STEP"
  ) 2>&1
}
called()     { [ -s "$STUB_LOG/$1.args" ]; }
# The step downloads into a `mktemp -d` under TMPDIR and must remove that dir on
# every exit path, so "cleaned up" == the sandbox download root is empty again.
dl_clean()   { [ -z "$(ls -A "$DL" 2>/dev/null)" ]; }
fresh_sandbox() { rm -f "$BIN/glab"; }

# ── 5. idempotency: glab already present → pure no-op ────────────────────────
fresh_sandbox
cat > "$BIN/glab" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = "--version" ] && printf 'glab %s (preinstalled)\n' "$VER"
EOF
chmod +x "$BIN/glab"
out="$(run_step amd64 "$SHA_AMD64")"; rc=$?
[ "$rc" = "0" ] && ok "already-installed: exits clean" || bad "already-installed: rc=$rc ($out)"
called curl   && bad "already-installed: downloaded anyway (not idempotent)" || ok "already-installed: no download"
called apt    && bad "already-installed: ran apt-get anyway"                 || ok "already-installed: no apt-get"
case "$out" in *"glab: glab $VER (preinstalled)"*) ok "already-installed: logs the live version" ;;
               *) bad "already-installed: version log line missing ($out)" ;; esac

# ── 6. fresh install per arch: right asset, right checksum, then install ─────
for a in amd64 arm64; do
  fresh_sandbox
  eval "sha=\$SHA_${a^^}"
  # shellcheck disable=SC2154  # assigned by the eval above
  out="$(run_step "$a" "$sha")"; rc=$?
  url="$(cat "$STUB_LOG/curl.args" 2>/dev/null)"
  [ "$rc" = "0" ] && ok "$a: exits clean" || bad "$a: rc=$rc ($out)"
  case "$url" in
    *"/v${VER}/downloads/glab_${VER}_linux_${a}.deb"*)
      ok "$a: downloads the pinned v$VER $a asset" ;;
    *) bad "$a: wrong download URL ($url)" ;;
  esac
  called apt && ok "$a: installs after the checksum matches" || bad "$a: apt-get never ran"
  case "$(cat "$STUB_LOG/apt.args" 2>/dev/null)" in
    *"glab_${VER}_linux_${a}.deb"*) ok "$a: apt-get installs the downloaded .deb" ;;
    *) bad "$a: apt-get did not receive the .deb ($(cat "$STUB_LOG/apt.args" 2>/dev/null))" ;;
  esac
  dl_clean && ok "$a: temp download dir cleaned up" || bad "$a: temp download dir left behind ($(ls -A "$DL"))"
  case "$out" in *"glab: glab $VER (stub)"*) ok "$a: logs the installed version" ;;
                 *) bad "$a: version log line missing ($out)" ;; esac
done

# ── 7. checksum mismatch → die, and NOTHING gets installed ───────────────────
# Feeding amd64 the arm64 digest also proves the arch→checksum map is not swapped.
fresh_sandbox
out="$(run_step amd64 "$SHA_ARM64")"; rc=$?
[ "$rc" != "0" ] && ok "checksum mismatch: dies" || bad "checksum mismatch: exited 0 — bad bytes would ship"
called apt && bad "checksum mismatch: installed unverified bytes" || ok "checksum mismatch: no install"
case "$out" in *"DIE: glab: checksum mismatch"*) ok "checksum mismatch: names the failure" ;;
               *) bad "checksum mismatch: unclear failure output ($out)" ;; esac
dl_clean && ok "checksum mismatch: bad .deb removed" \
  || bad "checksum mismatch: bad .deb left behind ($(ls -A "$DL"))"

# ── 8. unpinned architecture → die before touching the network ───────────────
fresh_sandbox
out="$(run_step armhf "$SHA_AMD64")"; rc=$?
[ "$rc" != "0" ] && ok "unpinned arch: dies" || bad "unpinned arch: exited 0"
called curl && bad "unpinned arch: downloaded an unpinned asset" || ok "unpinned arch: no download"
called apt  && bad "unpinned arch: installed something"          || ok "unpinned arch: no install"
case "$out" in *"DIE: glab: unsupported architecture 'armhf'"*) ok "unpinned arch: names the arch" ;;
               *) bad "unpinned arch: unclear failure output ($out)" ;; esac

echo "-----------------------------------------------"
[ "$fail" = "0" ] && echo "test-03b-glab-cli: PASS" || echo "test-03b-glab-cli: FAIL"
exit "$fail"
