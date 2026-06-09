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
. "$BASE_DIR/07-claude-code.sh"
. "$BASE_DIR/08-sidebutton.sh"       # gated on SKIP_SIDEBUTTON_SERVER
. "$BASE_DIR/09-agent-user.sh"

# Toolchain components (root; run after the agent user exists so docker can add
# it to the docker group). Each is idempotent and self-gated by selection here.
for _tc in dotnet9 docker postgres-client openvpn; do
  if has_component "$_tc" && [ -f "$BASE_DIR/components/$_tc/install.sh" ]; then
    . "$BASE_DIR/components/$_tc/install.sh"
  fi
done

. "$BASE_DIR/11-polkit.sh"
. "$BASE_DIR/12-workspace.sh"
. "$BASE_DIR/13-knowledge-packs.sh"  # gated on SKIP_KNOWLEDGE_PACKS
. "$BASE_DIR/14-claude-stop-hook.sh"
. "$BASE_DIR/15-claude-mcp.sh"       # gated on SKIP_SIDEBUTTON_SERVER
. "$BASE_DIR/15b-claude-onboarding.sh"
. "$BASE_DIR/16-services-prep.sh"    # chrome.service gated on INSTALL_CHROME
. "$BASE_DIR/16b-wallpaper.sh"

# ── pre-services phase ──────────────────────────────────────────────────────
if [ "${INSTALL_EXTENSION:-0}" = "1" ] && [ -f "$BASE_DIR/components/sidebutton-extension/pre-services.sh" ]; then
  . "$BASE_DIR/components/sidebutton-extension/pre-services.sh"
fi
run_variant_hook "pre-services"

. "$BASE_DIR/17-services-start.sh"   # chrome enable/start gated on INSTALL_CHROME

# ── post-services phase ─────────────────────────────────────────────────────
if [ "${INSTALL_EXTENSION:-0}" = "1" ] && [ -f "$BASE_DIR/components/sidebutton-extension/post-services.sh" ]; then
  . "$BASE_DIR/components/sidebutton-extension/post-services.sh"
fi
run_variant_hook "post-services"

. "$BASE_DIR/18-heartbeat.sh"
. "$BASE_DIR/18b-heartbeat-timer.sh"  # recurring online beat when serverless
. "$BASE_DIR/19-secrets.sh"
. "$BASE_DIR/19b-plugins.sh"         # installs SIDEBUTTON_PLUGINS; starts SB server
. "$BASE_DIR/19c-health-report.sh"   # gated on SKIP_SIDEBUTTON_SERVER
. "$BASE_DIR/19d-account-registry.sh"
. "$BASE_DIR/20-mark-installed.sh"
