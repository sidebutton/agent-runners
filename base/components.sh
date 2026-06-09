#!/usr/bin/env bash
# base/components.sh — resolve the agent's component set + derive step gates.
#
# Sourced by base/run.sh right after lib.sh. Turns the AGENT_COMPONENTS env list
# (comma- or space-separated component slugs from components.json) into:
#   - has_component <slug>   helper used by run.sh to gate phases
#   - the SKIP_*/INSTALL_*/SIDEBUTTON_PLUGINS gates the existing step scripts read
#
# Back-compat: if AGENT_COMPONENTS is unset, the set is derived from the legacy
# AGENT_RUNNER variant so old cloud-init keeps producing the same install.

# Legacy AGENT_RUNNER variant → component set.
_legacy_runner_components() {
  case "${1:-}" in
    sidebutton-mcp-claude-code-extension|"")
      echo "chrome sidebutton-server sidebutton-extension knowledge-packs screen-record" ;;
    sidebutton-mcp-claude-code)
      echo "chrome sidebutton-server knowledge-packs screen-record" ;;
    ubuntu-claude-code)
      echo "" ;;                       # bare base — no optional components
    *)
      echo "chrome sidebutton-server sidebutton-extension knowledge-packs screen-record" ;;
  esac
}

if [ -n "${AGENT_COMPONENTS:-}" ]; then
  _components="$(printf '%s' "$AGENT_COMPONENTS" | tr ',' ' ')"
else
  _components="$(_legacy_runner_components "${AGENT_RUNNER:-}")"
fi
# Space-pad the normalised list so word matches are unambiguous.
COMPONENTS=" $(echo $_components | xargs) "
export COMPONENTS

has_component() { case "$COMPONENTS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Derived gates consumed by the existing base step scripts (minimal churn):
# the steps test `= "1"`, so a non-"1" value means "install / don't skip".
has_component sidebutton-server && export SKIP_SIDEBUTTON_SERVER=0 || export SKIP_SIDEBUTTON_SERVER=1
has_component knowledge-packs   && export SKIP_KNOWLEDGE_PACKS=0   || export SKIP_KNOWLEDGE_PACKS=1
has_component chrome            && export INSTALL_CHROME=1         || export INSTALL_CHROME=0
has_component sidebutton-extension && export INSTALL_EXTENSION=1   || export INSTALL_EXTENSION=0

# mcp-plugin components → SIDEBUTTON_PLUGINS (consumed by 19b-plugins.sh). An
# explicit SIDEBUTTON_PLUGINS env still wins (operator override).
if [ -z "${SIDEBUTTON_PLUGINS:-}" ]; then
  _plugins=""
  for _c in screen-record writing-quality; do
    has_component "$_c" && _plugins="${_plugins}${_plugins:+,}${_c}"
  done
  export SIDEBUTTON_PLUGINS="$_plugins"
fi

# Enforce hard prerequisites (components.json `requires`) defensively, so a
# dependent never installs broken even if a caller sends an inconsistent set.
# The wizard normally guarantees consistency; for the canonical profile presets
# below this block is a no-op (no logs).
if has_component sidebutton-extension; then
  [ "$INSTALL_CHROME" = 1 ]            || { log "components: sidebutton-extension requires chrome — enabling"; export INSTALL_CHROME=1; }
  [ "$SKIP_SIDEBUTTON_SERVER" = 0 ]    || { log "components: sidebutton-extension requires sidebutton-server — enabling"; export SKIP_SIDEBUTTON_SERVER=0; }
fi
if [ "$SKIP_KNOWLEDGE_PACKS" = 0 ] && [ "$SKIP_SIDEBUTTON_SERVER" != 0 ]; then
  log "components: knowledge-packs requires sidebutton-server — enabling"; export SKIP_SIDEBUTTON_SERVER=0
fi
if [ -n "${SIDEBUTTON_PLUGINS:-}" ] && [ "$SKIP_SIDEBUTTON_SERVER" != 0 ]; then
  log "components: mcp-plugins require sidebutton-server — enabling"; export SKIP_SIDEBUTTON_SERVER=0
fi

log "components: [$(echo $COMPONENTS | xargs)]"
log "  gates: server=$([ "$SKIP_SIDEBUTTON_SERVER" = 0 ] && echo on || echo off) chrome=${INSTALL_CHROME} extension=${INSTALL_EXTENSION} packs=$([ "$SKIP_KNOWLEDGE_PACKS" = 0 ] && echo on || echo off) plugins=[${SIDEBUTTON_PLUGINS:-}]"
