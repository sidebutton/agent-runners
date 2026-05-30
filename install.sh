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

AGENT_RUNNER="${AGENT_RUNNER:-sidebutton-mcp-claude-code-extension}"
RUNNERS_REF="${RUNNERS_REF:-local}"
BOOTSTRAP_VERSION="${BOOTSTRAP_VERSION:-2.0.0}"

if [ ! -d "$SCRIPT_DIR/variants/$AGENT_RUNNER" ]; then
  echo "ERROR: unknown AGENT_RUNNER='$AGENT_RUNNER'" >&2
  echo "Available variants: $(ls -1 "$SCRIPT_DIR/variants" 2>/dev/null | tr '\n' ' ')" >&2
  exit 1
fi

export AGENT_RUNNER RUNNERS_REF BOOTSTRAP_VERSION
export RUNNERS_ROOT="$SCRIPT_DIR"
export RUNNERS_VARIANT_DIR="$SCRIPT_DIR/variants/$AGENT_RUNNER"

exec bash "$SCRIPT_DIR/base/run.sh"
