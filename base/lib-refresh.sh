#!/usr/bin/env bash
# base/lib-refresh.sh — shared, change-gated refresh of a live agent's deployed
# artifacts: the agent-runners BASE ARTIFACTS (SCRUM-1380) AND the universal
# "agents" CATALOG OPS PACK (the default ops workflows — companion to SCRUM-1380,
# closing the knowledge-pack half of the same fleet-drift story) AND the CLAUDE
# CODE CLI (kept at the version in components/claude-code/version, `latest` by
# default — the runtime half of the same story).
#
# Single source of truth for "re-apply the idempotent base artifacts on a live
# agent" so the fleet self-service path and the operator break-glass path can
# never drift:
#   - base/assets/sb-self-update.sh  (root wrapper, run fleet-wide by the
#     agent_pull_repos ops job via `sudo sb-self-update`)
#   - the-assistant agent-redeploy.sh §4/§4b  (operator manual-SSH break-glass)
# Both download agent-runners@<ref> to a tmp tree, then source THIS file from that
# tree and call sb_refresh_base_artifacts "<tree>/base" "<ref>".
#
# Design (maps to SCRUM-1380 items 1-3):
#   - Manifest-driven (base/refresh-manifest.txt), not a hard-coded step list, so
#     newly added refresh-safe steps reach the fleet without editing two callers.
#   - Change-gated by a fingerprint over the deployed artifacts vs the marker
#     (/etc/sidebutton/updated): a routine pull_repos tick where nothing upstream
#     changed is a true no-op — no rewrite, no service bounce.
#   - Runs as root but writes agent-owned files, so it chowns artifacts back to
#     ${AGENT_USER} (the wrapper historically only touched root-owned npm state).
#
# Expects lib.sh already sourced for log()/AGENT_USER/AGENT_HOME; falls back to a
# minimal log() and sane defaults so the file is unit-testable on its own.

command -v log >/dev/null 2>&1 || log() { printf '[lib-refresh] %s\n' "$*" >&2; }

SB_UPDATED_MARKER="${SB_UPDATED_MARKER:-/etc/sidebutton/updated}"
SB_SELF_UPDATE_BIN="${SB_SELF_UPDATE_BIN:-/usr/local/bin/sb-self-update}"

# sb_refresh_manifest_files <base_dir> — echo the manifest step filenames in order,
# stripping blank lines and whole-line / trailing `#` comments.
sb_refresh_manifest_files() {
  local mf="$1/refresh-manifest.txt"
  [ -r "$mf" ] || return 0
  sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "$mf" | awk 'NF'
}

# sb_base_artifacts_fingerprint <base_dir> — stable sha256 over everything that
# determines what gets deployed: the manifest steps, the hooks asset, the wrapper
# asset, this lib, and the manifest itself. Same ref + unchanged tree => same
# fingerprint on every box, so the change-gate is deterministic. A change to ANY
# of these (incl. the wrapper or a newly listed step) flips the fingerprint and
# triggers a refresh.
sb_base_artifacts_fingerprint() {
  local base="$1" f
  {
    while IFS= read -r f; do
      [ -f "$base/$f" ] && cat "$base/$f"
    done < <(sb_refresh_manifest_files "$base")
    # Assets deployed by manifest steps but not themselves steps: the self-update
    # wrapper, the sb-config-place / sb-config-reconcile helpers installed by 19f,
    # the health reporter installed by 19c (report-health-snapshot.sh — an
    # asset that 19c copies to /opt, so a reporter-only edit leaves 19c's own bytes
    # unchanged and would NOT flip the fingerprint; SCRUM-1626), and the registry
    # sync helper installed by 19d (same trap; KAN-150). Listing them here
    # makes a wrapper/reconcile/reporter/registry-only change flip the fingerprint
    # (else the change-gate would skip the refresh and the fleet would keep the old
    # artifact — the exact drift SCRUM-1380 exists to prevent).
    for f in assets/claude-hooks.json assets/sb-self-update.sh \
             assets/sb-config-place.sh assets/sb-config-reconcile.sh \
             assets/report-health-snapshot.sh assets/sb-reboot.sh \
             assets/sb-registry-sync.sh \
             lib-refresh.sh refresh-manifest.txt; do
      [ -f "$base/$f" ] && cat "$base/$f"
    done
  } 2>/dev/null | sha256sum | awk '{print $1}'
}

# sb_artifacts_current <fp_new> <ref_new> [marker] — true (0) when the marker
# already records this exact fingerprint AND ref, i.e. nothing to do.
sb_artifacts_current() {
  local fp_new="$1" ref_new="$2" marker="${3:-$SB_UPDATED_MARKER}"
  [ -r "$marker" ] || return 1
  local fp_old ref_old
  fp_old=$(sed -n 's/^base_artifacts_sha=//p' "$marker" | tail -1)
  ref_old=$(sed -n 's/^runners_ref=//p' "$marker" | tail -1)
  [ -n "$fp_old" ] && [ "$fp_old" = "$fp_new" ] && [ "$ref_old" = "$ref_new" ]
}

# _sb_merge_claude_hooks <hooks_asset> — re-merge the canonical hooks block over
# the live ~/.claude/settings.json, preserving every other key (mcpServers,
# onboarding, env). Echoes a status word; chowns the result back to the agent.
_sb_merge_claude_hooks() {
  local hooks_asset="$1"
  local settings="${AGENT_HOME:-/home/agent}/.claude/settings.json"
  if ! command -v jq >/dev/null 2>&1; then echo "skipped (no jq)"; return 0; fi
  if [ ! -f "$hooks_asset" ]; then echo "no asset"; return 0; fi
  if [ ! -f "$settings" ]; then echo "no settings.json"; return 0; fi
  local before after
  before=$(sha256sum "$settings" | awk '{print $1}')
  if jq --slurpfile h "$hooks_asset" '.hooks = $h[0].hooks' "$settings" > "${settings}.tmp" 2>/dev/null \
      && [ -s "${settings}.tmp" ] && jq -e '.hooks' "${settings}.tmp" >/dev/null 2>&1; then
    mv "${settings}.tmp" "$settings"
    chown "${AGENT_USER:-agent}:${AGENT_USER:-agent}" "$settings" 2>/dev/null || true
    after=$(sha256sum "$settings" | awk '{print $1}')
    [ "$before" = "$after" ] && echo "unchanged" || echo "updated"
  else
    rm -f "${settings}.tmp"
    echo "failed"
  fi
}

# _sb_reinstall_wrapper <base_dir> — keep /usr/local/bin/sb-self-update current
# from the fetched tree so wrapper fixes propagate via the fleet path itself.
# Best-effort + validated (non-empty, has a shebang) so a bad fetch can't brick
# the one privileged action.
_sb_reinstall_wrapper() {
  local src="$1/assets/sb-self-update.sh"
  [ -f "$src" ] || return 0
  head -1 "$src" | grep -q '^#!' || { log "wrapper asset has no shebang — not reinstalling"; return 0; }
  if [ -f "$SB_SELF_UPDATE_BIN" ] && cmp -s "$src" "$SB_SELF_UPDATE_BIN"; then
    return 0
  fi
  if install -m 0755 "$src" "$SB_SELF_UPDATE_BIN" 2>/dev/null; then
    log "sb-self-update wrapper reinstalled from ${1}"
  else
    log "WARN: could not reinstall sb-self-update wrapper"
  fi
}

# _sb_run_as_agent <user> <cmd> — run <cmd> as the agent user. In the prod wrapper
# context we are root, so drop to the agent user (the pack lives under its HOME);
# in tests / already-agent contexts run it directly so it needs no tty/su.
_sb_run_as_agent() {
  local user="$1" cmd="$2"
  if [ "$(id -u)" -eq 0 ] && [ "$(id -un)" != "$user" ]; then
    su - "$user" -c "$cmd"
  else
    eval "$cmd"
  fi
}

# _sb_run_base_step <base_dir> <step_file> [have_sb] — source ONE base step in an
# isolated subshell with the env contract base/run.sh provides (lib.sh helpers,
# AGENT_USER/AGENT_HOME, BASE_DIR for bundled assets, the component gates, a sourced
# ~/.agent-env). Output goes to the step's own log only; returns the step's status.
# Shared by the manifest loop and the Claude Code step's 15b re-run. have_sb (0/1)
# defaults to whether the sidebutton.service unit exists.
_sb_run_base_step() {
  local base="$1" step_file="$2" have_sb="${3:-}"
  if [ -z "$have_sb" ]; then
    have_sb=0
    [ -n "$(systemctl list-unit-files sidebutton.service --no-legend 2>/dev/null)" ] && have_sb=1
  fi
  (
    set -euo pipefail
    export AGENT_USER="${AGENT_USER:-agent}" AGENT_HOME="${AGENT_HOME:-/home/agent}"
    export BASE_DIR="$base"
    if [ "$have_sb" -ne 1 ]; then
      export SKIP_SIDEBUTTON_SERVER=1 SKIP_KNOWLEDGE_PACKS=1
    fi
    set -a
    [ -f "${AGENT_HOME:-/home/agent}/.agent-env" ] && . "${AGENT_HOME:-/home/agent}/.agent-env"
    set +a
    . "$base/lib.sh"
    . "$base/$step_file"
  ) >/dev/null 2>&1
}

# ── SideButton server CLI (npm global) — hardened, self-repairing upgrade ─────
# Powers sidebutton.service (:9876). `npm install -g sidebutton@latest` mutates the
# global prefix IN PLACE: npm "retires" the live package dir AND the
# /usr/bin/sidebutton bin link to temp names, extracts the new version, then swaps.
# If the disk fills mid-extract (ENOSPC) npm aborts and its rollback can leave the
# bin link stranded and the dep tree half-extracted — the package is present but
# `sidebutton` no longer execs (systemd 203/EXEC) or dies ERR_MODULE_NOT_FOUND. The
# running server masks it until the next restart/reboot, then crash-loops. So we
# (1) DISK-PREFLIGHT before ever attempting the install, and (2) VERIFY + REPAIR
# (relink, else one clean reinstall) so a corrupted install self-heals on the next
# pull_repos instead of bricking the agent. The server-variant gate is the STABLE
# sidebutton.service unit, NOT `command -v sidebutton`: a lost bin link must trigger
# repair, not be mistaken for a serverless box (that latch is what made the original
# breakage permanent — RCA 2026-06-28, agent-awsdjo-lamport).
SB_MIN_FREE_MB="${SB_MIN_FREE_MB:-1024}"   # refuse the in-place npm -g below this headroom

_sb_have_unit() { [ -n "$(systemctl list-unit-files "$1" --no-legend 2>/dev/null)" ]; }

# Healthy = the bin resolves on PATH AND actually runs (its deps load). hash -r so a
# freshly (re)created symlink is seen rather than a stale PATH cache.
_sb_server_cli_healthy() {
  hash -r 2>/dev/null || true
  command -v sidebutton >/dev/null 2>&1 && sidebutton --version >/dev/null 2>&1
}

# Network-free repair: when the package dir is intact but the bin link is gone,
# recreate <bindir>/sidebutton from the package's own bin field. Returns healthy?
_sb_relink_server_bin() {
  local pkgroot="$1" bindir="$2" pkg="$1/sidebutton" rel binpath
  [ -f "$pkg/package.json" ] || return 1
  rel="$(node -e 'try{const b=require(process.argv[1]+"/package.json").bin;process.stdout.write(typeof b==="string"?b:(b&&b.sidebutton)||"")}catch(e){}' "$pkg" 2>/dev/null)"
  [ -n "$rel" ] || return 1
  binpath="$pkg/${rel#./}"
  [ -f "$binpath" ] || return 1
  ln -sfn "$binpath" "$bindir/sidebutton" 2>/dev/null || return 1
  chmod +x "$binpath" 2>/dev/null || true
  _sb_server_cli_healthy
}

# sb_refresh_server_cli — upgrade the global SideButton CLI/server, prevented from
# bricking the agent and self-healing if it finds (or produces) a broken install.
# Best-effort: returns 0 on upgrade/no-op/serverless/low-disk; returns 1 only when
# the install is broken AND unrepairable (and then it does NOT restart the service,
# leaving the running process alone rather than bouncing it into a crash-loop).
# Detail -> log(); a one-line status -> stdout (surfaces in the pull_repos report).
sb_refresh_server_cli() {
  if ! _sb_have_unit sidebutton.service; then
    log "server CLI: no sidebutton.service (serverless) — skipped"
    return 0
  fi

  # The server now defaults to a loopback bind and refuses a wide bind without a
  # token (SCRUM-1490). Backfill SIDEBUTTON_HOST=0.0.0.0 into .agent-env BEFORE
  # the (possibly newly upgraded) server restarts below, so existing fleet agents
  # — provisioned before this knob existed — keep binding the VM's private IP for
  # the relay/Temporal path instead of silently dropping to loopback. Idempotent;
  # append preserves the file's agent ownership + 0600 mode.
  local _env="${AGENT_HOME:-/home/agent}/.agent-env"
  if [ -f "$_env" ] && ! grep -q '^SIDEBUTTON_HOST=' "$_env"; then
    printf 'SIDEBUTTON_HOST=0.0.0.0\n' >> "$_env"
    log "server CLI: backfilled SIDEBUTTON_HOST=0.0.0.0 into .agent-env (loopback-default upgrade compat)"
  fi

  local prefix pkgroot bindir
  prefix="$(npm prefix -g 2>/dev/null)"; [ -n "$prefix" ] || prefix="/usr"
  pkgroot="$prefix/lib/node_modules"
  bindir="$prefix/bin"

  # (1) disk preflight — a full disk is exactly what corrupts an in-place npm -g.
  local free_mb
  free_mb="$(df -Pm "$pkgroot" 2>/dev/null | awk 'NR==2 {print $4+0}')"
  if [ -n "$free_mb" ] && [ "$free_mb" -lt "$SB_MIN_FREE_MB" ]; then
    log "WARN: server CLI: only ${free_mb}MB free at ${pkgroot} (<${SB_MIN_FREE_MB}MB) — skipping npm upgrade to avoid a partial install"
    echo "sidebutton CLI: upgrade skipped (low disk ${free_mb}MB)"
    return 0
  fi

  local before after
  before="$(sidebutton --version 2>/dev/null || echo none)"
  npm install -g sidebutton@latest >/dev/null 2>&1 || log "WARN: server CLI: npm install returned non-zero"

  # (2) verify + repair the ENOSPC-class corruption (stranded bin / half-extracted deps).
  if ! _sb_server_cli_healthy; then
    log "server CLI: install unhealthy after upgrade — repairing (relink)"
    if ! _sb_relink_server_bin "$pkgroot" "$bindir"; then
      log "server CLI: relink insufficient — one clean reinstall (disk known-OK)"
      npm install -g sidebutton@latest >/dev/null 2>&1 || true
    fi
    if ! _sb_server_cli_healthy; then
      log "WARN: server CLI: STILL broken after repair — leaving sidebutton.service untouched (manual fix / reprovision needed)"
      echo "sidebutton CLI: BROKEN after repair — not restarting"
      return 1
    fi
    log "server CLI: repaired"
  fi

  after="$(sidebutton --version 2>/dev/null || echo none)"
  if [ "$before" != "$after" ]; then
    systemctl restart sidebutton 2>/dev/null || log "WARN: server CLI: restart failed"
    local i up=0
    for i in $(seq 1 15); do
      curl -sf --max-time 2 http://localhost:9876/health >/dev/null 2>&1 && { up=1; break; }
      sleep 1
    done
    if [ "$up" = 1 ]; then
      log "server CLI: ${before} -> ${after} (restarted, :9876 up)"
    else
      log "WARN: server CLI: ${before} -> ${after} (restarted, :9876 NOT up within 15s)"
    fi
    echo "sidebutton CLI: ${before} -> ${after}"
  else
    log "server CLI: already at ${after} (no change)"
    echo "sidebutton CLI: ${after} current"
  fi
  return 0
}

# ── Claude Code CLI (npm global) — kept at the fleet's target version ─────────
# Claude Code is installed ONCE at provisioning (components/claude-code/install.sh,
# skipped whenever `claude` exists) with its autoupdater off (base/09
# DISABLE_AUTOUPDATER=1), so without this step every agent stays on the release of
# its provisioning day. That is not cosmetic: a model the portal binds that needs a
# newer CLI fails every job at its first request (API 400 "Claude Code X does not
# support this model; version Y or newer is required") and the job then sits at the
# prompt. This converges the npm-global install on the version named in
# components/claude-code/version: `latest` (the default — the fleet runs the latest
# Claude Code) or an exact version, which holds or rolls back the whole fleet on its
# next self-update when a release goes bad.
#
# Called from sb_refresh_base_artifacts BEFORE its fingerprint gate, for the reason
# the ops-pack reconcile is: a live agent runs the wrapper installed at provisioning,
# which only calls sb_refresh_server_cli + sb_refresh_base_artifacts from the freshly
# downloaded lib — so this lands on the very next self-update, not one run later.
#
# Hardened like sb_refresh_server_cli, plus what is specific to this binary:
#   - REFRESH-ONLY: acts on an existing npm-global install and never installs one
#     (a component set without claude-code stays without it).
#   - Disk preflight before the in-place npm -g (the ENOSPC brick, RCA 2026-06-28).
#   - DOWNLOAD FIRST: `npm cache add` the package and its platform binary while the
#     live install is untouched, then install --prefer-offline, which only extracts.
#     The wrapper usually runs inside a Claude Bash tool call that has a timeout, so
#     the window in which the install is half swapped must stay short.
#   - VERIFY the PREFIX-LOCAL binary — never `command -v claude`, which finds whatever
#     else is on PATH (the trap that keeps test-sb-self-update.sh in ci-exclude.txt).
#     Broken => one clean reinstall => roll back to the previous version: an agent is
#     never left without a working claude.
#   - NO sidebutton.service restart: this runs inside a job, and the unit has no
#     KillMode (base/16-services-prep.sh), so a restart can take down job terminals.
#     A running claude keeps its binary; new sessions start on the new one.
# 15b-claude-onboarding re-runs whenever the installed version differs from the
# release-notes stamp it wrote (lastReleaseNotesSeen) — after this step's upgrade or
# anyone else's — so the "What's new" panel never comes back over a job terminal.
#
# Best-effort: returns 0 on upgrade / no-op / skip / successful rollback, 1 only when
# claude is left broken. Detail -> log(); ONE status line -> stdout, which the Self
# Update report quotes. Kill-switch: SKIP_CLAUDE_CODE_UPDATE=1 (also the test guard).
SB_CLAUDE_PKG="${SB_CLAUDE_PKG:-@anthropic-ai/claude-code}"
SB_CLAUDE_VERSION_FILE="${SB_CLAUDE_VERSION_FILE:-components/claude-code/version}"

# First x.y.z token on stdin ("" when there is none).
_sb_semver() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }

# _sb_claude_want <base_dir> — the configured target: `latest` or an exact version.
_sb_claude_want() {
  local f="$1/$SB_CLAUDE_VERSION_FILE" want=""
  [ -r "$f" ] && want="$(sed -e 's/#.*$//' "$f" | awk 'NF {print $1; exit}')"
  printf '%s\n' "${want:-latest}"
}

# _sb_claude_target <want> — an exact version passes through; a dist-tag is resolved
# against the registry. Echoes x.y.z, or nothing when the registry is unreachable.
_sb_claude_target() {
  local want="$1"
  if printf '%s' "$want" | grep -qxE '[0-9]+\.[0-9]+\.[0-9]+'; then
    printf '%s\n' "$want"
    return 0
  fi
  timeout "${SB_NPM_VIEW_TIMEOUT:-60}" npm view "${SB_CLAUDE_PKG}@${want}" version 2>/dev/null | _sb_semver
}

# _sb_claude_pkg_version <pkg_dir> — version from the installed package.json. Read,
# not exec'd, so it answers even when the binary is broken. "" when absent.
_sb_claude_pkg_version() {
  local pj="$1/package.json"
  [ -f "$pj" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r '.version // empty' "$pj" 2>/dev/null
  else
    sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pj" | head -1
  fi
}

# _sb_claude_runs <bin_dir> <version> — the prefix-local claude executes and reports
# exactly <version>.
_sb_claude_runs() {
  local got
  got="$("$1/claude" --version 2>/dev/null | _sb_semver)"
  [ -n "$got" ] && [ "$got" = "$2" ]
}

# _sb_claude_platform_pkg — the optional dependency that carries this box's native
# binary (the heavy part of the download). "" when unknown: the install then fetches
# it itself.
_sb_claude_platform_pkg() {
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64)  printf '%s\n' "${SB_CLAUDE_PKG}-linux-x64" ;;
    aarch64|arm64) printf '%s\n' "${SB_CLAUDE_PKG}-linux-arm64" ;;
  esac
}

# _sb_claude_install <version> — the in-place global install, served from the npm
# cache when the download-first step filled it.
_sb_claude_install() {
  timeout "${SB_NPM_INSTALL_TIMEOUT:-600}" npm install -g "${SB_CLAUDE_PKG}@$1" --prefer-offline >/dev/null 2>&1 \
    || log "WARN: claude code: npm install -g ${SB_CLAUDE_PKG}@$1 returned non-zero"
  hash -r 2>/dev/null || true
}

# _sb_claude_onboarding_sync <base_dir> <version> — re-run 15b when the release-notes
# stamp in ~/.claude.json is not <version>.
_sb_claude_onboarding_sync() {
  local base="$1" ver="$2" seen=""
  local claude_json="${AGENT_HOME:-/home/agent}/.claude.json"
  [ -n "$ver" ] || return 0
  if [ ! -f "$base/15b-claude-onboarding.sh" ]; then
    log "WARN: claude code: 15b-claude-onboarding.sh missing in tree — onboarding stamp not refreshed"
    return 0
  fi
  if [ -f "$claude_json" ] && command -v jq >/dev/null 2>&1; then
    seen="$(jq -r '.lastReleaseNotesSeen // empty' "$claude_json" 2>/dev/null)"
  fi
  [ "$seen" = "$ver" ] && return 0
  if _sb_run_base_step "$base" 15b-claude-onboarding.sh; then
    log "claude code: 15b re-run (release notes ${seen:-unset} -> ${ver})"
  else
    log "WARN: claude code: 15b re-run failed (see ${LOG_FILE:-log})"
  fi
}

# sb_refresh_claude_code <base_dir> — see the section comment above.
sb_refresh_claude_code() {
  local base="$1"
  if [ "${SKIP_CLAUDE_CODE_UPDATE:-}" = "1" ]; then
    log "claude code: skipped (SKIP_CLAUDE_CODE_UPDATE=1)"
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1; then
    log "claude code: npm absent — skipped"
    return 0
  fi

  local prefix pkgroot bindir pkgdir
  prefix="$(npm prefix -g 2>/dev/null)"; [ -n "$prefix" ] || prefix="/usr"
  pkgroot="$prefix/lib/node_modules"
  bindir="$prefix/bin"
  pkgdir="$pkgroot/$SB_CLAUDE_PKG"
  if [ ! -f "$pkgdir/package.json" ]; then
    log "claude code: no npm-global install at ${pkgdir} — skipped (refresh-only, never installs)"
    echo "claude code: not installed via npm — skipped"
    return 0
  fi

  local want before target
  want="$(_sb_claude_want "$base")"
  before="$(_sb_claude_pkg_version "$pkgdir")"
  target="$(_sb_claude_target "$want")"
  if [ -z "$target" ]; then
    log "WARN: claude code: could not resolve '${want}' from the npm registry — upgrade skipped, retried next self-update"
    _sb_claude_onboarding_sync "$base" "$before"
    echo "claude code: ${before:-unknown} (could not resolve ${want} — upgrade skipped)"
    return 0
  fi

  if [ "$before" = "$target" ] && _sb_claude_runs "$bindir" "$target"; then
    log "claude code: already at ${target} (no change)"
    _sb_claude_onboarding_sync "$base" "$target"
    echo "claude code: ${target} current"
    return 0
  fi

  # (1) disk preflight — a full disk is what corrupts an in-place npm -g.
  local free_mb
  free_mb="$(df -Pm "$pkgroot" 2>/dev/null | awk 'NR==2 {print $4+0}')"
  if [ -n "$free_mb" ] && [ "$free_mb" -lt "$SB_MIN_FREE_MB" ]; then
    log "WARN: claude code: only ${free_mb}MB free at ${pkgroot} (<${SB_MIN_FREE_MB}MB) — upgrade to ${target} skipped to avoid a partial install"
    echo "claude code: ${before:-unknown} (upgrade to ${target} skipped: low disk ${free_mb}MB)"
    return 0
  fi

  # (2) download first — the live install is untouched while the network works.
  local plat; plat="$(_sb_claude_platform_pkg)"
  if timeout "${SB_NPM_FETCH_TIMEOUT:-600}" npm cache add "${SB_CLAUDE_PKG}@${target}" ${plat:+"${plat}@${target}"} >/dev/null 2>&1; then
    log "claude code: ${target} fetched into the npm cache${plat:+ (with ${plat})}"
  else
    log "WARN: claude code: prefetch of ${target} failed — the install downloads it itself"
  fi

  # (3) swap, verify the prefix-local binary, one clean reinstall, then roll back.
  _sb_claude_install "$target"
  if ! _sb_claude_runs "$bindir" "$target"; then
    log "claude code: ${target} does not run after the install — one clean reinstall"
    _sb_claude_install "$target"
  fi
  if ! _sb_claude_runs "$bindir" "$target"; then
    if [ -n "$before" ] && [ "$before" != "$target" ]; then
      log "WARN: claude code: ${target} still does not run — rolling back to ${before}"
      _sb_claude_install "$before"
      if _sb_claude_runs "$bindir" "$before"; then
        _sb_claude_onboarding_sync "$base" "$before"
        echo "claude code: upgrade to ${target} FAILED — rolled back to ${before}"
        return 0
      fi
    fi
    log "WARN: claude code: BROKEN after the install of ${target} — manual fix / reprovision needed"
    echo "claude code: BROKEN after upgrade to ${target} — manual fix needed"
    return 1
  fi

  _sb_claude_onboarding_sync "$base" "$target"
  if [ "$before" = "$target" ]; then
    log "claude code: ${target} did not run — repaired by reinstall"
    echo "claude code: ${target} repaired"
  else
    log "claude code: ${before:-unknown} -> ${target}"
    echo "claude code: ${before:-unknown} -> ${target}"
  fi
  return 0
}

# sb_refresh_knowledge_packs [pack] — reconcile the universal "agents" catalog ops
# pack (the default ops workflows: agent_pull_repos, agent_se_*, agent_qa_*, …) so
# workflows added or changed after this agent was provisioned actually reach it.
#
# WHY this is SEPARATE from the base-artifact refresh and NOT a manifest step: the
# default workflows live in the sidebutton-skill-packs CATALOG, not in agent-runners,
# so they move on a different cadence and must not be gated on the agent-runners
# fingerprint. They reach an agent ONLY via `sidebutton install` against the public
# catalog; nothing else refreshes them — `sidebutton registry update` pulls only git
# REGISTRIES (base/19d), and the base-artifact manifest deliberately excludes the
# one-time provisioning step that installs this pack (base/13). Left unaddressed, a
# newly published default workflow 404s ("Workflow not found") on every already-
# provisioned agent when the orchestrator dispatches it by id.
#
# CHANGE-GATE = the CLI's own version compare (installSkillPack), so we need no
# version math here and an unchanged catalog rewrites nothing:
#   - same version already installed  -> plain install is a no-op (exit 0, "skipped")
#   - catalog moved to a new version  -> plain install refuses    (exit 1, "Use --force")
#   - not installed at all            -> plain install would install it — but the
#                                        refresh-only gate below skips this case first
# A plain install, then --force only on its failure, converges to the catalog version
# while staying a TRUE no-op when nothing changed (one cheap catalog GET, no rewrite).
#
# REFRESH-ONLY: reconciles a pack this agent ALREADY has; it never fresh-installs one
# the agent was provisioned without — components.sh allows a sidebutton-server agent
# with knowledge-packs OFF (SKIP_KNOWLEDGE_PACKS=1 ⇒ base/13 skipped), and that
# choice must be respected even though the CLI is present.
#
# Best-effort: never aborts the caller (always returns 0); a catalog-unreachable tick
# just logs and is retried on the next pull_repos. Gated off on serverless boxes (no
# `sidebutton` CLI) and by SKIP_KNOWLEDGE_PACKS=1 (parity with base/13; also the test
# kill-switch). Detail goes to log() (stderr/logfile); a one-line status is echoed to
# stdout only when it actually acts, so it surfaces in the pull_repos report.
sb_refresh_knowledge_packs() {
  local pack="${1:-agents}"
  local user="${AGENT_USER:-agent}"
  local home="${AGENT_HOME:-/home/${user}}"

  if [ "${SKIP_KNOWLEDGE_PACKS:-}" = "1" ]; then
    log "knowledge packs: skipped (SKIP_KNOWLEDGE_PACKS=1)"
    return 0
  fi
  if ! command -v sidebutton >/dev/null 2>&1; then
    log "knowledge packs: sidebutton CLI absent (serverless) — skipped"
    return 0
  fi
  # Refresh only what is already installed (CLI getConfigDir = ~/.sidebutton, packs
  # under skills/<domain>) — never fresh-install onto a deliberately packs-less agent.
  if [ ! -d "${home}/.sidebutton/skills/${pack}" ]; then
    log "knowledge packs: '${pack}' not installed on this agent — skipped (not fresh-installing)"
    return 0
  fi

  # Plain install first: exit 0 when already current, non-zero when a DIFFERENT
  # version is installed (the CLI's "Use --force" refusal).
  if _sb_run_as_agent "$user" "sidebutton install ${pack}" >/dev/null 2>&1; then
    log "knowledge packs: '${pack}' already at catalog version (no change)"
    echo "knowledge packs: ${pack} current"
    return 0
  fi

  # Non-zero — most commonly catalog drift; converge by forcing. (A genuine error,
  # e.g. the catalog unreachable, also lands here; the forced retry then fails too
  # and we log it without aborting the rest of the refresh.)
  if _sb_run_as_agent "$user" "sidebutton install ${pack} --force" >/dev/null 2>&1; then
    log "knowledge packs: '${pack}' refreshed to catalog version (--force)"
    echo "knowledge packs: ${pack} refreshed"
  else
    log "WARN: knowledge packs: '${pack}' refresh failed (catalog unreachable?) — retry next pull_repos"
    echo "knowledge packs: ${pack} refresh FAILED"
  fi
  return 0
}

# sb_refresh_base_artifacts <base_dir> <runners_ref> — the change-gated apply.
# Returns 0 on success or no-op; 1 only on an unusable tree. Individual step
# failures are logged (status=partial) but never abort, matching the break-glass
# tool's tolerance.
sb_refresh_base_artifacts() {
  local base="$1" ref="${2:-unknown}"
  if [ ! -r "$base/refresh-manifest.txt" ]; then
    log "ERROR: no refresh-manifest.txt under ${base} — base artifacts not refreshed"
    return 1
  fi

  # Catalog ops pack — reconciled on EVERY call, BEFORE (and independent of) the
  # base-artifact change-gate below: the default workflows live in the skill-packs
  # catalog and move on their own cadence, and an agent still on a pre-this wrapper
  # only ever calls THIS function, so doing it here makes a catalog bump land on the
  # same pull_repos pass. It self-gates (CLI version compare), so this is a no-op
  # when the pack is already current.
  sb_refresh_knowledge_packs

  # Claude Code CLI — also before the change-gate, for the same reason: the wrapper
  # on a live agent predates this step and only ever calls THIS function. It
  # self-gates on installed vs target version, so it is a no-op when current.
  sb_refresh_claude_code "$base" || true

  local fp; fp=$(sb_base_artifacts_fingerprint "$base")
  if sb_artifacts_current "$fp" "$ref"; then
    log "base artifacts already current (ref=${ref} sha=${fp:0:12}) — no refresh"
    echo "base artifacts: already current (${fp:0:12})"
    return 0
  fi
  log "refreshing base artifacts (ref=${ref} sha=${fp:0:12})"

  # Component gates: a refresh on a serverless / no-packs box must not try to
  # install the SB-server-only or registry-only artifacts. Mirror the gate the
  # break-glass tool uses — tie both to whether the SB server unit exists.
  local have_sb=0
  systemctl list-unit-files sidebutton.service --no-legend >/dev/null 2>&1 \
    && [ -n "$(systemctl list-unit-files sidebutton.service --no-legend 2>/dev/null)" ] && have_sb=1

  # Keep the wrapper itself current (it is part of the fingerprint).
  _sb_reinstall_wrapper "$base"

  local status="synced" step_file
  while IFS= read -r step_file; do
    [ -f "$base/$step_file" ] || { log "WARN: manifest step ${step_file} missing in tree — skipped"; status="partial"; continue; }
    if _sb_run_base_step "$base" "$step_file" "$have_sb"; then
      log "ok:   ${step_file}"
    else
      log "WARN: ${step_file} failed (see ${LOG_FILE:-log})"
      status="partial"
    fi
  done < <(sb_refresh_manifest_files "$base")

  local hooks_status; hooks_status=$(_sb_merge_claude_hooks "$base/assets/claude-hooks.json")
  log "claude hooks: ${hooks_status}"

  # Root wrote agent-owned artifacts (~/.local/bin scripts from step 14); hand
  # them back. settings.json is already chowned in the merge above.
  chown -R "${AGENT_USER:-agent}:${AGENT_USER:-agent}" "${AGENT_HOME:-/home/agent}/.local/bin" 2>/dev/null || true

  mkdir -p "$(dirname "$SB_UPDATED_MARKER")"
  {
    echo "updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "runners_ref=${ref}"
    # A FAILED hooks merge (jq/write error, unparseable settings.json) must not
    # latch the change-gate: manifest steps may have removed scripts the live
    # settings still reference, so omit base_artifacts_sha and let the next
    # pull_repos tick retry the whole pass (sb_artifacts_current needs the sha).
    # 'skipped (no jq)' / 'no settings.json' / 'no asset' DO latch — those boxes
    # can never merge, and retrying every tick would be a refresh loop.
    if [ "$hooks_status" != "failed" ]; then
      echo "base_artifacts_sha=${fp}"
    fi
  } > "$SB_UPDATED_MARKER"
  [ "$hooks_status" = "failed" ] && log "WARN: hooks merge failed — change-gate left open to retry next tick"

  log "base artifacts refreshed (ref=${ref} sha=${fp:0:12} steps=${status} hooks=${hooks_status})"
  echo "base artifacts: refreshed (${fp:0:12}, steps=${status}, hooks=${hooks_status})"
  return 0
}
