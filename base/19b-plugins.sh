# 19b-plugins.sh — install the agent plugins the portal selected, then start the
# SideButton server (its first start) now that its runtime env is complete.
#
# SIDEBUTTON_PLUGINS is a comma-separated list of plugin slugs forwarded by the
# provisioner (a profile's default_plugins ∪ the provision request override).
# Each slug resolves to a public git repo via plugins.json (repo root). Plugins
# are MCP tools hosted by the SideButton server, so this step is a no-op on
# variants without a server (SKIP_SIDEBUTTON_SERVER=1, e.g. ubuntu-claude-code).
#
# sidebutton.service is enabled in base/17 but deliberately NOT started there: at
# that point ~/.agent-env still holds the single-use bootstrap token + empty
# GH_TOKEN. base/18 then swaps in the permanent sb_token and base/19 writes the
# secrets, so by here the env is complete — start the server ONCE, with the right
# token + secrets (+ any plugins just installed). systemd reads the
# EnvironmentFile only at start, so starting here (instead of start-early-in-17 +
# restart) means the server is never up with a stale env: no 401 on portal->agent
# calls (Bearer is checked against env SIDEBUTTON_AGENT_TOKEN in server.ts) and no
# failed workspace clone (gh reads GH_TOKEN from the server's env).

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
        else
          log "WARN: 'sidebutton plugin install' failed for ${slug}"
        fi
      else
        log "WARN: git clone failed for ${slug} (https://github.com/${repo}.git@${ref})"
      fi
      su - "$AGENT_USER" -c "rm -rf '${tmp}'" 2>/dev/null || true
    done
  fi
fi

# First and only start of the server, now that the token + secrets (+ any
# plugins) are in ~/.agent-env — see header. Runs for every server variant. On
# reboot systemd starts it normally (it was enabled in base/17).
if [ "${SKIP_SIDEBUTTON_SERVER:-}" != "1" ]; then
  log "Starting sidebutton with the populated agent env..."
  systemctl start sidebutton || log "WARN: failed to start sidebutton — starts on next boot"
fi
