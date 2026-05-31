# 19b-plugins.sh — install the agent plugins the portal selected.
#
# SIDEBUTTON_PLUGINS is a comma-separated list of plugin slugs forwarded by the
# provisioner (a profile's default_plugins ∪ the provision request override).
# Each slug resolves to a public git repo via plugins.json (repo root). Plugins
# are MCP tools hosted by the SideButton server, so this step is a no-op on
# variants without a server (SKIP_SIDEBUTTON_SERVER=1, e.g. ubuntu-claude-code).
#
# Ordering: runs AFTER 19-secrets so the `systemctl restart sidebutton` at the
# end loads BOTH the freshly installed plugins AND the now-populated .agent-env
# (writing-quality reads ANTHROPIC_API_KEY from the server's process env at
# runtime). The clone is anonymous — the catalog ships only public repos.

if [ "${SKIP_SIDEBUTTON_SERVER:-}" = "1" ]; then
  step "Step 19b: Agent plugins (skipped — no SideButton server on this variant)"
elif [ -z "${SIDEBUTTON_PLUGINS:-}" ]; then
  step "Step 19b: Agent plugins (none requested)"
else
  step "Step 19b: Agent plugins (${SIDEBUTTON_PLUGINS})"
  PLUGINS_CATALOG="${BASE_DIR}/../plugins.json"
  if [ ! -f "$PLUGINS_CATALOG" ]; then
    log "WARN: plugins catalog not found at ${PLUGINS_CATALOG} — skipping plugin install"
  else
    installed_any=0
    IFS=',' read -ra _plugin_slugs <<< "${SIDEBUTTON_PLUGINS}"
    for raw_slug in "${_plugin_slugs[@]}"; do
      slug="$(printf '%s' "$raw_slug" | tr -d '[:space:]')"
      [ -z "$slug" ] && continue

      entry="$(jq -c --arg s "$slug" '.plugins[] | select(.slug == $s)' "$PLUGINS_CATALOG" 2>/dev/null || true)"
      if [ -z "$entry" ]; then
        log "WARN: plugin '${slug}' not in catalog — skipping"
        continue
      fi

      repo="$(printf '%s' "$entry" | jq -r '.repo')"
      ref="$(printf '%s' "$entry" | jq -r '.ref // "main"')"
      submodules="$(printf '%s' "$entry" | jq -r '.submodules // false')"
      sysdeps="$(printf '%s' "$entry" | jq -r '(.system_deps // []) | join(" ")')"

      if [ -n "$sysdeps" ]; then
        log "plugin ${slug}: installing system deps (${sysdeps})"
        # shellcheck disable=SC2086
        apt-get install "${APT_OPTS[@]}" $sysdeps || log "WARN: apt-get install '${sysdeps}' failed for ${slug}"
      fi

      recurse=""
      [ "$submodules" = "true" ] && recurse="--recurse-submodules"

      tmp="$(su - "$AGENT_USER" -c 'mktemp -d')"
      if su - "$AGENT_USER" -c "git clone --depth 1 ${recurse} --branch '${ref}' 'https://github.com/${repo}.git' '${tmp}' 2>&1" >/dev/null; then
        if su - "$AGENT_USER" -c "sidebutton plugin install '${tmp}' 2>&1"; then
          log "plugin installed: ${slug} (${repo}@${ref})"
          installed_any=1
        else
          log "WARN: 'sidebutton plugin install' failed for ${slug}"
        fi
      else
        log "WARN: git clone failed for ${slug} (https://github.com/${repo}.git@${ref})"
      fi
      su - "$AGENT_USER" -c "rm -rf '${tmp}'" 2>/dev/null || true
    done

    if [ "$installed_any" = "1" ]; then
      log "Restarting sidebutton to load plugins + secrets..."
      systemctl restart sidebutton || log "WARN: failed to restart sidebutton — plugins load on next start"
    else
      log "No plugins installed — skipping sidebutton restart"
    fi
  fi
fi
