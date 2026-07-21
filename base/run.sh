#!/usr/bin/env bash
# base/run.sh — orchestrator for the install step scripts.
# Invoked by the thin bootstrapper at website/public/install.sh after the
# agent-runners repo has been downloaded and AGENT_RUNNER/RUNNERS_VARIANT_DIR
# have been exported.
#
# Model (see docs/COMPONENTS.md): a single base runner (ubuntu-claude-code) plus
# OPTIONAL COMPONENTS selected via AGENT_COMPONENTS. base/components.sh resolves
# that list (back-compat: derived from the legacy AGENT_RUNNER when unset) into
# the SKIP_*/INSTALL_* gates the step scripts read + the has_component helper.
# The variant hook mechanism is retained (run_variant_hook) but the single base
# variant ships no hooks — component behaviour (extension, toolchains) is driven
# from here.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib.sh
. "$BASE_DIR/lib.sh"

log "SideButton agent-runners base v${BOOTSTRAP_VERSION:-unknown} starting"
log "RUNNERS_VARIANT_DIR=${RUNNERS_VARIANT_DIR:-unset}"

. "$BASE_DIR/01-preflight.sh"
# Resolve AGENT_COMPONENTS → component set + step gates (has_component, SKIP_*, …).
# shellcheck source=./components.sh
. "$BASE_DIR/components.sh"
run_variant_hook "early-setup"

# ── Install phase ───────────────────────────────────────────────────────────
. "$BASE_DIR/02-system.sh"
. "$BASE_DIR/03-gh-cli.sh"
. "$BASE_DIR/04-desktop.sh"
. "$BASE_DIR/05-node.sh"
. "$BASE_DIR/06-chrome.sh"           # gated on INSTALL_CHROME
# Claude Code CLI — componentized (gated on INSTALL_CLAUDE_CODE; default-on for
# manual / back-compat sets). Position unchanged: before 08/09 and the
# 14/15/15b steps that configure Claude (which stay in base, ungated).
if [ "${INSTALL_CLAUDE_CODE:-0}" = "1" ] && [ -f "$BASE_DIR/components/claude-code/install.sh" ]; then
  . "$BASE_DIR/components/claude-code/install.sh"
fi
. "$BASE_DIR/08-sidebutton.sh"       # gated on SKIP_SIDEBUTTON_SERVER
. "$BASE_DIR/09-agent-user.sh"

# Toolchain components (root; run after the agent user exists so docker can add
# it to the docker group). Each is idempotent and self-gated by selection here.
for _tc in dotnet9 android-sdk docker postgres-client openvpn wireguard rdp-client; do
  if has_component "$_tc" && [ -f "$BASE_DIR/components/$_tc/install.sh" ]; then
    . "$BASE_DIR/components/$_tc/install.sh"
  fi
done

# Claude Code Router (CCR) — a runtime component (proxy that routes Claude Code to
# a configured provider), wired as a dedicated, greppable include rather than via
# the toolchain loop. Runs here, after 09 (it writes + chowns ~/.claude-code-router)
# and after the claude-code install above (components.sh enforces that requirement).
# install.sh only ENABLES ccr.service; its first start is the post-services phase,
# after 19-secrets populates ~/.agent-env with the routing env CCR resolves at runtime.
if has_component claude-code-router && [ -f "$BASE_DIR/components/claude-code-router/install.sh" ]; then
  . "$BASE_DIR/components/claude-code-router/install.sh"
fi

. "$BASE_DIR/11-polkit.sh"
. "$BASE_DIR/12-workspace.sh"
. "$BASE_DIR/13-knowledge-packs.sh"  # gated on SKIP_KNOWLEDGE_PACKS
. "$BASE_DIR/14-claude-stop-hook.sh"
. "$BASE_DIR/15-claude-mcp.sh"       # gated on SKIP_SIDEBUTTON_SERVER
. "$BASE_DIR/15b-claude-onboarding.sh"
. "$BASE_DIR/16-services-prep.sh"    # chrome.service gated on INSTALL_CHROME
. "$BASE_DIR/16b-wallpaper.sh"

# ── pre-services phase ──────────────────────────────────────────────────────
# Generalized over any selected component that ships a pre-services.sh (was
# hardcoded to sidebutton-extension). `has_component sidebutton-extension` is
# exactly INSTALL_EXTENSION (the gate derives only from it), so non-extension
# agents stay behaviour-identical; the -f guard skips a component with no
# pre-services script (claude-code-router ships only post-services).
for _c in sidebutton-extension claude-code-router; do
  if has_component "$_c" && [ -f "$BASE_DIR/components/$_c/pre-services.sh" ]; then
    . "$BASE_DIR/components/$_c/pre-services.sh"
  fi
done
run_variant_hook "pre-services"

. "$BASE_DIR/17-services-start.sh"   # chrome enable/start gated on INSTALL_CHROME
# NOTE: 17 only ENABLES sidebutton.service; its single start is deferred to 19b
# (so it boots once with a complete ~/.agent-env). The extension handshake-wait
# therefore cannot run here — it lives in the post-services phase below, after 19b.
run_variant_hook "post-services"

. "$BASE_DIR/18-heartbeat.sh"
. "$BASE_DIR/18b-heartbeat-timer.sh"  # recurring online beat when serverless
. "$BASE_DIR/19-secrets.sh"
. "$BASE_DIR/19b-plugins.sh"         # installs SIDEBUTTON_PLUGINS; starts SB server

# ── post-services phase (extension handshake) ───────────────────────────────
# Chrome force-installs the extension back at step 17, but browser_connected can
# only flip true once the server on :9876 is listening — which 19b just started.
# Running this wait BEFORE 19b (its previous position) could never succeed: it
# always exhausted its retry budget, logged a false "browser_connected did not
# become true" WARN, and wasted ~4min bouncing Chrome, recovering only
# incidentally ~5s after 19b. Waiting HERE — after the server start and before
# 19c starts the health reporter — means the first health POST already carries
# browser_connected=true (no transient portal 'error'), and the restart-retry
# inside post-services.sh becomes meaningful (it can now reach a live server).
# Same generalization as the pre-services loop: iterate any selected component
# that ships a post-services.sh. The extension waits for browser_connected here;
# claude-code-router first-starts ccr.service + health-checks it (both need the
# complete ~/.agent-env that 19/19b just produced).
for _c in sidebutton-extension claude-code-router; do
  if has_component "$_c" && [ -f "$BASE_DIR/components/$_c/post-services.sh" ]; then
    . "$BASE_DIR/components/$_c/post-services.sh"
  fi
done

. "$BASE_DIR/18c-git-telemetry-timer.sh"  # git-telemetry reconcile timer (SCRUM-513) — never sourced before
. "$BASE_DIR/19c-health-report.sh"   # gated on SKIP_SIDEBUTTON_SERVER
. "$BASE_DIR/19d-account-registry.sh"
. "$BASE_DIR/19e-session-tidy.sh"     # close finished Claude TUIs after a TTL (SCRUM-1769)
. "$BASE_DIR/19f-component-config.sh" # component config-file watchers + sb-config-place (SCRUM-1599)
. "$BASE_DIR/20-mark-installed.sh"
