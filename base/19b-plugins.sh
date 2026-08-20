# 19b-plugins.sh — install the agent plugins the portal selected, then start the
# SideButton server (its first start) now that its runtime env is complete.
#
# SIDEBUTTON_PLUGINS is a comma-separated list of plugin slugs the portal selected
# (role-driven, from plugins.json) and passed in cloud-init. Each slug resolves to
# a public git repo via plugins.json (repo root). Plugins are MCP tools hosted by
# the SideButton server, so this step is a no-op without a server
# (SKIP_SIDEBUTTON_SERVER=1, e.g. a manual base agent).
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
#
# ARGV, NEVER A COMMAND STRING (SCRUM-1982). This step used to build its `su -c`
# arguments by interpolation — `su - agent -c "git clone … --branch '${ref}' …"`
# — and to word-split `$sysdeps` straight from the catalog into a ROOT
# `apt-get install`. `su -c` re-parses its argument as shell, so a metacharacter
# anywhere in plugins.json was a command, and the quoting around ${ref} was the
# only thing standing between catalog data and code execution. That was tolerable
# only because the catalog is first-party — and it is exactly the pattern the
# operator-typed CLAUDE_PLUGINS in base/19i must never inherit, so it is fixed
# here in the same pass rather than left as precedent. Every value is now
# validated against a strict pattern and passed as an ARGV ELEMENT.

# owner/repo, bounded to GitHub's own limits (owner ≤ 39, repo ≤ 100).
PLUGIN_REPO_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'
# A git branch / tag / sha. Slashes allowed (release/1.2); shell metacharacters,
# whitespace and a leading dash (which would read as a git option) are not.
PLUGIN_REF_RE='^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$'
# A Debian package name — the only thing that may reach a root apt-get.
PLUGIN_APT_RE='^[a-z0-9][a-z0-9.+-]{0,99}$'

# Run a command as the agent user with each value bound to a POSITIONAL, so the
# value is never re-parsed as shell. Twin of _cc_as_agent in base/19i.
#
# The `--` is load-bearing, not decoration. util-linux `su` parses its options
# with GNU getopt PERMUTATION: without a terminator it keeps scanning past the
# username and eats any dash-argument meant for the command. `mktemp -d` dies on
# `su: invalid option -- 'd'`, `git clone --depth 1` on `unrecognized option
# '--depth'`, and `claude plugin install ref -s user` is worse still — `-s` is a
# real su option, so it is silently swallowed as --shell and never reaches the
# command. `--` stops the scan; everything after it is an operand.
_19b_as_agent() {
  su - "$AGENT_USER" -s /bin/bash -c 'exec "$@"' -- _ "$@"
}

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

      if ! [[ "$repo" =~ $PLUGIN_REPO_RE ]]; then
        log "WARN: plugin '${slug}' has an unusable repo in the catalog — skipping (nothing executed)"
        continue
      fi
      if ! [[ "$ref" =~ $PLUGIN_REF_RE ]]; then
        log "WARN: plugin '${slug}' has an unusable ref in the catalog — skipping (nothing executed)"
        continue
      fi

      if [ -n "$sysdeps" ]; then
        read -r -a _sysdep_raw <<< "$sysdeps"
        _sysdep_pkgs=()
        for _pkg in "${_sysdep_raw[@]}"; do
          if [[ "$_pkg" =~ $PLUGIN_APT_RE ]]; then
            _sysdep_pkgs+=("$_pkg")
          else
            log "WARN: plugin ${slug}: rejecting system dep '${_pkg}' — not a package name, never passed to apt"
          fi
        done
        if [ "${#_sysdep_pkgs[@]}" -gt 0 ]; then
          log "plugin ${slug}: installing system deps (${_sysdep_pkgs[*]})"
          apt-get install "${APT_OPTS[@]}" "${_sysdep_pkgs[@]}" \
            || log "WARN: apt-get install '${_sysdep_pkgs[*]}' failed for ${slug}"
        fi
      fi

      clone_args=(git clone --depth 1)
      [ "$submodules" = "true" ] && clone_args+=(--recurse-submodules)
      clone_args+=(--branch "$ref" "https://github.com/${repo}.git")

      tmp="$(_19b_as_agent mktemp -d 2>/dev/null || true)"
      if [ -z "$tmp" ]; then
        log "WARN: could not create a temp dir as ${AGENT_USER} for ${slug} — skipping"
        continue
      fi
      if _19b_as_agent "${clone_args[@]}" "$tmp" >/dev/null 2>&1; then
        if _19b_as_agent sidebutton plugin install "$tmp"; then
          log "plugin installed: ${slug} (${repo}@${ref})"
        else
          log "WARN: 'sidebutton plugin install' failed for ${slug}"
        fi
      else
        log "WARN: git clone failed for ${slug} (https://github.com/${repo}.git@${ref})"
      fi
      _19b_as_agent rm -rf "$tmp" 2>/dev/null || true
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
