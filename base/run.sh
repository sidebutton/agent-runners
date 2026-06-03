#!/usr/bin/env bash
# base/run.sh — orchestrator for the install step scripts.
# Invoked by the thin bootstrapper at website/public/install.sh after the
# agent-runners repo has been downloaded and AGENT_RUNNER/RUNNERS_VARIANT_DIR
# have been exported. Sources each step file in numeric order, calling the
# variant overlay hooks at the two well-defined points (pre-services /
# post-services).

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib.sh
. "$BASE_DIR/lib.sh"

log "SideButton agent-runners base v${BOOTSTRAP_VERSION:-unknown} starting"
log "RUNNERS_VARIANT_DIR=${RUNNERS_VARIANT_DIR:-unset}"

. "$BASE_DIR/01-preflight.sh"
run_variant_hook "early-setup"
. "$BASE_DIR/02-system.sh"
. "$BASE_DIR/03-gh-cli.sh"
. "$BASE_DIR/04-desktop.sh"
. "$BASE_DIR/05-node.sh"
. "$BASE_DIR/06-chrome.sh"
. "$BASE_DIR/07-claude-code.sh"
. "$BASE_DIR/08-sidebutton.sh"
. "$BASE_DIR/09-agent-user.sh"
. "$BASE_DIR/11-polkit.sh"
. "$BASE_DIR/12-workspace.sh"
. "$BASE_DIR/13-knowledge-packs.sh"
. "$BASE_DIR/14-claude-stop-hook.sh"
. "$BASE_DIR/15-claude-mcp.sh"
. "$BASE_DIR/15b-claude-onboarding.sh"
. "$BASE_DIR/16-services-prep.sh"
. "$BASE_DIR/16b-wallpaper.sh"
run_variant_hook "pre-services"
. "$BASE_DIR/17-services-start.sh"
run_variant_hook "post-services"
. "$BASE_DIR/18-heartbeat.sh"
. "$BASE_DIR/19-secrets.sh"
. "$BASE_DIR/19b-plugins.sh"
. "$BASE_DIR/19c-health-report.sh"
. "$BASE_DIR/19d-account-registry.sh"
. "$BASE_DIR/20-mark-installed.sh"
