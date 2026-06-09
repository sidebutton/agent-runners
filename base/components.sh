#!/usr/bin/env bash
# base/components.sh — resolve the agent's component set + derive step gates.
#
# Sourced by base/run.sh right after lib.sh. Turns the AGENT_COMPONENTS env list
# (comma- or space-separated component slugs from components.json) into:
#   - has_component <slug>   helper used by run.sh to gate phases
#   - the SKIP_*/INSTALL_* gates the existing step scripts read
#
# AGENT_COMPONENTS is the authoritative selection (the portal always sends it).
# Unset/empty ⇒ a manual base agent (no optional components).
_components="$(printf '%s' "${AGENT_COMPONENTS:-}" | tr ',' ' ')"
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

# SIDEBUTTON_PLUGINS is selected by the portal (role-driven, from plugins.json)
# and passed explicitly in cloud-init; 19b-plugins.sh consumes it. Nothing to
# derive here — plugins are no longer components.

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
  log "components: plugins require sidebutton-server — enabling"; export SKIP_SIDEBUTTON_SERVER=0
fi

log "components: [$(echo $COMPONENTS | xargs)]"
log "  gates: server=$([ "$SKIP_SIDEBUTTON_SERVER" = 0 ] && echo on || echo off) chrome=${INSTALL_CHROME} extension=${INSTALL_EXTENSION} packs=$([ "$SKIP_KNOWLEDGE_PACKS" = 0 ] && echo on || echo off) plugins=[${SIDEBUTTON_PLUGINS:-}]"
