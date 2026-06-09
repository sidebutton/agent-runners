#!/usr/bin/env bash
# agent-runners/install.sh — direct entry point for running the installer
# straight from a cloned/extracted agent-runners checkout (e.g. during local
# development, when working from a fork, or when piping a downloaded tarball
# rather than the thin website bootstrapper).
#
# Production usage normally goes through https://sidebutton.com/install.sh
# (the thin bootstrapper); this file lets the same flow run end-to-end without
# that bootstrapper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Single base runner (named after its deps). The capability composition lives in
# AGENT_COMPONENTS (see components.json / docs/COMPONENTS.md), not the runner.
AGENT_RUNNER="${AGENT_RUNNER:-ubuntu-claude-code}"
RUNNERS_REF="${RUNNERS_REF:-local}"
BOOTSTRAP_VERSION="${BOOTSTRAP_VERSION:-2.0.0}"

# Resolve the variant dir. Legacy runner names (pre component model) no longer
# have their own dir — fall back to the single base variant. AGENT_RUNNER is left
# as-passed so base/components.sh can map a legacy name → component set (only used
# when AGENT_COMPONENTS is unset); the new path passes AGENT_COMPONENTS directly.
VARIANT_DIR="$SCRIPT_DIR/variants/$AGENT_RUNNER"
if [ ! -d "$VARIANT_DIR" ]; then
  echo "WARN: AGENT_RUNNER='$AGENT_RUNNER' has no variants/ dir — using base 'ubuntu-claude-code'" >&2
  VARIANT_DIR="$SCRIPT_DIR/variants/ubuntu-claude-code"
fi

export AGENT_RUNNER RUNNERS_REF BOOTSTRAP_VERSION
export AGENT_COMPONENTS="${AGENT_COMPONENTS:-}"
export RUNNERS_ROOT="$SCRIPT_DIR"
export RUNNERS_VARIANT_DIR="$VARIANT_DIR"

exec bash "$SCRIPT_DIR/base/run.sh"
