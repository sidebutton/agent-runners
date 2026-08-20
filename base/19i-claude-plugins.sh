# 19i-claude-plugins.sh — install the Claude Code plugins the operator picked in
# the Create-Agent wizard, and report the per-plugin result (SCRUM-1982).
#
# SCRUM-1981 made the set operator-selectable and threads it to the box as
# cloud-init env: CLAUDE_PLUGINS="name@marketplace,…" plus the optional
# CLAUDE_PLUGIN_MARKETPLACES="alias=owner/repo,…" for any marketplace the CLI
# does not already know. Until this step nothing on the box read either var —
# the wizard field validated beautifully and installed nothing, a fully silent
# no-op.
#
# DO NOT CROSS THE WIRES WITH 19b. That step installs SIDEBUTTON_PLUGINS: MCP
# tools hosted by the SideButton server, from plugins.json, via
# `sidebutton plugin install`. This step drives Claude Code's OWN plugin store —
# `claude plugin install <name>@<marketplace>` into ~/.claude/plugins — a
# separate system with its own catalog, install path and settings keys. The two
# are adjacent here only because both are called "plugins"; nothing else is
# shared.
#
# WHY 19i: 19g (agent reboot, SCRUM-1926) and 19h (tmux status) are taken.
# Ordering is not a free choice — `claude plugin install` writes to
# $AGENT_HOME/.claude AS THE AGENT USER, so the step must run after base/09
# (creates ~/.claude + ~/.sidebutton), after base/15b (seeds ~/.claude.json) and
# after base/17 (chowns $AGENT_HOME back to the agent). Sitting at the end of the
# 19x block satisfies all three, keeps the step post-secrets so a future
# credentialed `--config` path needs no repositioning, and keeps both plugin
# installs adjacent.
#
# GATE — `command -v claude`, deliberately NOT INSTALL_CLAUDE_CODE. This step is
# listed in refresh-manifest.txt, and base/lib-refresh.sh does NOT source
# components.sh: on the refresh path INSTALL_CLAUDE_CODE is simply unset, so a
# component gate here would evaluate differently at provision vs refresh and
# silently skip the ENTIRE fleet. `command -v claude` is necessary, sufficient,
# and identical on both paths. base/tests/test-19e-session-tidy.sh already
# codifies that rule for refresh-listed steps; test-19i-claude-plugins.sh
# asserts it for this one.
#
# REFRESH-SAFE / SELF-HEALING. The *normalised* request is persisted into
# ~/.agent-env, because the refresh path exports only AGENT_USER/AGENT_HOME/
# BASE_DIR and then sources ~/.agent-env — without the persist a refresh-listed
# 19i would see CLAUDE_PLUGINS="" forever: the fleet would get the script and
# never the plugins, and a box whose provision-time install failed could never
# repair itself. Both CLI calls are genuinely idempotent (probed against claude
# 2.1.212: re-adding a known marketplace and re-installing an installed plugin
# both exit 0), and the change-gate below skips them entirely when every
# requested ref is already installed — so the routine agent_pull_repos cadence
# costs two cheap local `--json` reads and no network. The ledger is rebuilt from
# `claude plugin list --json` on every path, so a no-change run rewrites it
# byte-identically.
#
# NEVER A SHELL STRING. Every operator-typed value is re-validated here against
# the same patterns the portal enforces (defence in depth — never trust that the
# portal validated) and is then passed as an ARGV ELEMENT. A rejected value never
# reaches an exec at all. This is exactly the 19b anti-pattern the same ticket
# fixes there: `su -c "… '$ref' …"` re-parses its argument as shell, so one
# metacharacter in catalog/operator data becomes a command. `su … -c 'exec "$@"'
# _ cmd args…` binds each value to a positional instead, so `evil; rm -rf /` is a
# plugin name the CLI rejects, not two commands root just ran.
#
# SUPPLY CHAIN. The official marketplace is an INDEX: its entries resolve to
# third-party repos, and plugin code lands on a box where Claude runs with
# skipDangerousModePermissionPrompt (base/09) and ~/.agent-env holds GH_TOKEN and
# the portal token. The account-scoped allowlist from SCRUM-1981 is the only
# control, so this step adds NO bypass: a marketplace is only ever added from a
# source that arrived in CLAUDE_PLUGIN_MARKETPLACES, never from a plugin ref.
#
# SOURCED, SO IT MUST NEVER EXIT. run.sh runs under `set -euo pipefail`; a bare
# exit/die here aborts the whole provision, and an unguarded non-zero command
# does the same (`claude plugin install` exits 1 on a missing plugin — probed).
# Every CLI call captures its status instead of letting it propagate, and a
# failed plugin is recorded, not fatal.

CC_LEDGER_DIR="${AGENT_HOME}/.sidebutton"
CC_LEDGER="${CC_LEDGER_DIR}/claude-plugins.json"
CC_ENV_FILE="${AGENT_HOME}/.agent-env"
# Mirrors MAX_CLAUDE_PLUGINS / DEFAULT_CLAUDE_MARKETPLACE in
# website/src/lib/cloud/claude-plugins.ts — the portal's own gate. Duplicated on
# purpose: this side has to hold even if a request ever arrives by another route.
CC_MAX_PLUGINS=20
CC_DEFAULT_MARKETPLACE="claude-plugins-official"
# CLAUDE_PLUGIN_NAME_RE / CLAUDE_MARKETPLACE_NAME_RE and
# CLAUDE_MARKETPLACE_SOURCE_RE from that same file. Narrower than what the CLI
# tolerates: they exclude every shell metacharacter, quote, space and newline.
CC_NAME_RE='^[a-z0-9][a-z0-9._-]{0,63}$'
CC_SOURCE_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'

# Run a command as the agent user with every value bound to a POSITIONAL — see
# the "never a shell string" note above. `-s /bin/bash` pins the shell so an
# operator-changed login shell cannot change the argv contract.
#
# The `--` is load-bearing. util-linux `su` parses options with GNU getopt
# PERMUTATION: with no terminator it keeps scanning past the username and eats
# dash-arguments meant for the command. `claude plugin list --json` dies on
# `su: unrecognized option '--json'`, and `claude plugin install <ref> -s user`
# is worse — `-s` is a real su option, so su swallows it as --shell and then
# tries to exec a shell literally named `user`. Both failures are total and
# silent-looking (every plugin just lands as `failed`). `--` ends the scan.
_cc_as_agent() {
  su - "$AGENT_USER" -s /bin/bash -c 'exec "$@"' -- _ "$@"
}

# `<alias>\t<repo>` for every marketplace already on the box. Local state only —
# no network — so it is safe to run on every refresh tick.
_cc_marketplace_tsv() {
  _cc_as_agent claude plugin marketplace list --json 2>/dev/null \
    | jq -r 'if type=="array" then .[] else empty end | [(.name // ""), (.repo // "")] | @tsv' 2>/dev/null || true
}

# `<name@marketplace>\t<version>` for every installed plugin. This — not the
# install command's stdout — is the ledger's source of truth. (`plugin list
# --available --json` returns a DIFFERENT shape, an object, not this array.)
_cc_installed_tsv() {
  _cc_as_agent claude plugin list --json 2>/dev/null \
    | jq -r 'if type=="array" then .[] else empty end | [(.id // ""), (.version // "")] | @tsv' 2>/dev/null || true
}

# One line of CLI output, trimmed, safe to put in a JSON string.
_cc_oneline() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/[[:space:]]\{2,\}/ /g; s/^ //; s/ $//' | tail -c 300
}

# Persist a NORMALISED value (already validated above) in systemd EnvironmentFile
# form: KEY="VALUE", no export, no shell expansion. Same grep-then-sed-else-append
# idiom as base/19d-account-registry.sh. Only validated values reach this, so the
# sed replacement can never carry a delimiter, a quote or a newline.
_cc_persist_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$CC_ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$CC_ENV_FILE"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$CC_ENV_FILE"
  fi
  return 0
}

if ! command -v claude >/dev/null 2>&1; then
  step "Step 19i/16: Claude Code plugins (skipped — no Claude Code CLI on this agent)"
elif [ -z "${CLAUDE_PLUGINS:-}" ]; then
  step "Step 19i/16: Claude Code plugins (none requested)"
elif ! command -v jq >/dev/null 2>&1; then
  step "Step 19i/16: Claude Code plugins (skipped — jq unavailable)"
  log "WARN: jq is required to reconcile marketplaces and write the ledger — Claude Code plugins not installed"
else
  step "Step 19i/16: Claude Code plugins (${CLAUDE_PLUGINS})"

  declare -a CC_REQ_NAME=() CC_REQ_MKT=() CC_BAD_REF=() CC_BAD_WHY=()
  declare -A CC_SEEN=() CC_SRC=() CC_ALIAS=() CC_VERSION=() CC_ERROR=()

  # ── 1. parse + re-validate the request ─────────────────────────────────────
  # A rejection is recorded in the ledger, never executed, and never aborts the
  # rest of the list (or of provisioning).
  IFS=',' read -r -a _cc_raw_refs <<< "${CLAUDE_PLUGINS}"
  for _cc_raw in "${_cc_raw_refs[@]}"; do
    _cc_tok="$(printf '%s' "$_cc_raw" | tr -d '[:space:]')"
    if [ -z "$_cc_tok" ]; then continue; fi
    if [ "${#CC_REQ_NAME[@]}" -ge "$CC_MAX_PLUGINS" ]; then
      CC_BAD_REF+=("$_cc_tok"); CC_BAD_WHY+=("over the ${CC_MAX_PLUGINS}-plugin cap — not installed")
      continue
    fi
    # `name` or `name@marketplace`. A trailing `@` is a typo, not "use the
    # default": the empty half fails the pattern and is rejected, as in the portal.
    _cc_name="${_cc_tok%%@*}"
    if [ "$_cc_tok" = "$_cc_name" ]; then
      _cc_mkt="$CC_DEFAULT_MARKETPLACE"
    else
      _cc_mkt="${_cc_tok#*@}"
    fi
    if ! [[ "$_cc_name" =~ $CC_NAME_RE ]] || ! [[ "$_cc_mkt" =~ $CC_NAME_RE ]]; then
      CC_BAD_REF+=("$_cc_tok"); CC_BAD_WHY+=("rejected by ${CC_NAME_RE} — never executed")
      log "WARN: Claude Code plugin reference failed re-validation — rejected, not executed"
      continue
    fi
    if [ -n "${CC_SEEN[${_cc_name}@${_cc_mkt}]:-}" ]; then continue; fi
    CC_SEEN["${_cc_name}@${_cc_mkt}"]=1
    CC_REQ_NAME+=("$_cc_name"); CC_REQ_MKT+=("$_cc_mkt")
  done

  # `alias=owner/repo` pairs. A marketplace with no usable source is NOT
  # pre-rejected: the box may already know the alias, so the install still gets
  # its chance and the CLI's own message lands in the ledger if it does not.
  if [ -n "${CLAUDE_PLUGIN_MARKETPLACES:-}" ]; then
    IFS=',' read -r -a _cc_raw_mkts <<< "${CLAUDE_PLUGIN_MARKETPLACES}"
    for _cc_raw in "${_cc_raw_mkts[@]}"; do
      _cc_pair="$(printf '%s' "$_cc_raw" | tr -d '[:space:]')"
      if [ -z "$_cc_pair" ]; then continue; fi
      _cc_alias="${_cc_pair%%=*}"
      _cc_src="${_cc_pair#*=}"
      if [[ "$_cc_alias" =~ $CC_NAME_RE ]] && [[ "$_cc_src" =~ $CC_SOURCE_RE ]]; then
        CC_SRC["$_cc_alias"]="$_cc_src"
      else
        log "WARN: Claude Code marketplace entry failed re-validation — rejected, never executed"
      fi
    done
  fi

  # ── 2. persist the normalised request so the refresh re-run has an input ───
  if [ ! -e "$CC_ENV_FILE" ]; then
    : > "$CC_ENV_FILE"
    chmod 600 "$CC_ENV_FILE" 2>/dev/null || true
    chown "${AGENT_USER}:${AGENT_USER}" "$CC_ENV_FILE" 2>/dev/null || true
  fi
  _cc_norm_refs=""
  for _cc_i in "${!CC_REQ_NAME[@]}"; do
    _cc_norm_refs="${_cc_norm_refs:+${_cc_norm_refs},}${CC_REQ_NAME[$_cc_i]}@${CC_REQ_MKT[$_cc_i]}"
  done
  _cc_norm_mkts=""
  for _cc_alias in "${!CC_SRC[@]}"; do
    _cc_norm_mkts="${_cc_norm_mkts:+${_cc_norm_mkts},}${_cc_alias}=${CC_SRC[$_cc_alias]}"
  done
  if [ -n "$_cc_norm_refs" ]; then
    _cc_persist_env CLAUDE_PLUGINS "$_cc_norm_refs"
    if [ -n "$_cc_norm_mkts" ]; then _cc_persist_env CLAUDE_PLUGIN_MARKETPLACES "$_cc_norm_mkts"; fi
    log "persisted the requested plugin set to ${CC_ENV_FILE} (refresh re-run + self-heal)"
  fi

  # ── 3. resolve each requested alias to the marketplace name ON DISK ────────
  # The alias is NOT ours to choose: ~/.claude/plugins/known_marketplaces.json is
  # keyed by the manifest's own `name`, which `marketplace add` takes from the
  # repo (the portal's allowlist POST already renames an admin's label to it for
  # the same reason, returning renamed_from). So resolve by REPO, never by the
  # alias we were handed — otherwise `install name@alias` fails "not found in
  # marketplace" for every third-party pack whose manifest disagrees with the
  # operator's label.
  _cc_resolve_aliases() {
    local mname mrepo alias src
    declare -A _by_repo=() _known=()
    while IFS=$'\t' read -r mname mrepo; do
      if [ -z "$mname" ]; then continue; fi
      _known["$mname"]=1
      if [ -n "$mrepo" ]; then _by_repo["$mrepo"]="$mname"; fi
    done < <(_cc_marketplace_tsv)
    for alias in "${CC_REQ_MKT[@]}"; do
      src="${CC_SRC[$alias]:-}"
      if [ -n "$src" ] && [ -n "${_by_repo[$src]:-}" ]; then
        CC_ALIAS["$alias"]="${_by_repo[$src]}"
      elif [ -n "${_known[$alias]:-}" ]; then
        CC_ALIAS["$alias"]="$alias"
      else
        CC_ALIAS["$alias"]=""
      fi
    done
    return 0
  }

  _cc_read_installed() {
    local id ver
    CC_VERSION=()
    while IFS=$'\t' read -r id ver; do
      if [ -n "$id" ]; then CC_VERSION["$id"]="$ver"; fi
    done < <(_cc_installed_tsv)
    return 0
  }

  # The ref this run will actually hand the CLI: the on-disk alias when we could
  # resolve one, else the requested alias so the CLI's own error is what the
  # operator sees. Section 6 installs it and section 7 looks it up — they must
  # agree, so both call this.
  _cc_effective_ref() {
    local name="$1" mkt="$2" alias
    alias="${CC_ALIAS[$mkt]:-}"
    if [ -z "$alias" ]; then alias="$mkt"; fi
    printf '%s@%s' "$name" "$alias"
  }

  # ── 4. change-gate ────────────────────────────────────────────────────────
  # Skip every exec when the box already has all of them. Cheap, local, and what
  # makes the step safe on the routine refresh cadence.
  _cc_resolve_aliases
  _cc_read_installed
  CC_ALL_PRESENT=1
  for _cc_i in "${!CC_REQ_NAME[@]}"; do
    _cc_ref="$(_cc_effective_ref "${CC_REQ_NAME[$_cc_i]}" "${CC_REQ_MKT[$_cc_i]}")"
    if [ -z "${CC_ALIAS[${CC_REQ_MKT[$_cc_i]}]:-}" ] || [ -z "${CC_VERSION[$_cc_ref]+x}" ]; then
      CC_ALL_PRESENT=0
      break
    fi
  done

  if [ "$CC_ALL_PRESENT" = "1" ] && [ "${#CC_REQ_NAME[@]}" -gt 0 ]; then
    log "all ${#CC_REQ_NAME[@]} requested Claude Code plugin(s) already installed — no marketplace or install call made"
  else
    # ── 5. marketplace add (idempotent), then re-resolve the aliases ─────────
    declare -A CC_ADDED=()
    for _cc_i in "${!CC_REQ_MKT[@]}"; do
      _cc_alias="${CC_REQ_MKT[$_cc_i]}"
      if [ -n "${CC_ADDED[$_cc_alias]:-}" ]; then continue; fi
      CC_ADDED["$_cc_alias"]=1
      _cc_src="${CC_SRC[$_cc_alias]:-}"
      # No source line for this alias: CLAUDE_PLUGIN_MARKETPLACES carries only
      # the github-sourced allowlist rows, so a name-only marketplace arrives
      # bare. Nothing to add; the install still runs and reports the CLI's error.
      if [ -z "$_cc_src" ]; then continue; fi
      if _cc_out="$(_cc_as_agent claude plugin marketplace add "$_cc_src" 2>&1)"; then
        log "marketplace ready: ${_cc_src}"
      else
        log "WARN: 'claude plugin marketplace add' failed for ${_cc_src}: $(_cc_oneline "$_cc_out")"
      fi
    done
    _cc_resolve_aliases

    # ── 6. install ──────────────────────────────────────────────────────────
    for _cc_i in "${!CC_REQ_NAME[@]}"; do
      _cc_ref="$(_cc_effective_ref "${CC_REQ_NAME[$_cc_i]}" "${CC_REQ_MKT[$_cc_i]}")"
      if _cc_out="$(_cc_as_agent claude plugin install "$_cc_ref" -s user 2>&1)"; then
        log "claude plugin installed: ${_cc_ref}"
      else
        CC_ERROR["$_cc_ref"]="$(_cc_oneline "$_cc_out")"
        log "WARN: 'claude plugin install' failed for ${_cc_ref} — recorded in the ledger, provisioning continues"
      fi
    done
    _cc_read_installed
  fi

  # ── 7. ledger ─────────────────────────────────────────────────────────────
  # Joined against `claude plugin list --json`, never against install stdout: a
  # plugin the CLI reports as installed IS installed, whatever this run did. The
  # `marketplace` field reports the REQUESTED alias (what the operator asked for
  # and what the portal stored); `version` and `status` come from the box.
  _cc_nd="$(mktemp)"
  for _cc_i in "${!CC_REQ_NAME[@]}"; do
    _cc_name="${CC_REQ_NAME[$_cc_i]}"
    _cc_mkt="${CC_REQ_MKT[$_cc_i]}"
    _cc_ref="$(_cc_effective_ref "$_cc_name" "$_cc_mkt")"
    if [ -n "${CC_VERSION[$_cc_ref]+x}" ]; then
      _cc_status="installed"; _cc_err=""; _cc_ver="${CC_VERSION[$_cc_ref]}"
    else
      _cc_status="failed"; _cc_ver=""
      _cc_err="${CC_ERROR[$_cc_ref]:-not reported by \`claude plugin list\` after install}"
    fi
    jq -n --arg n "$_cc_name" --arg m "$_cc_mkt" --arg s "$_cc_status" --arg v "$_cc_ver" --arg e "$_cc_err" \
      '{name:$n, marketplace:$m, status:$s, version:(if $v=="" then null else $v end), error:(if $e=="" then null else $e end)}' \
      >> "$_cc_nd" 2>/dev/null || true
  done
  for _cc_i in "${!CC_BAD_REF[@]}"; do
    jq -n --arg n "${CC_BAD_REF[$_cc_i]}" --arg e "${CC_BAD_WHY[$_cc_i]}" \
      '{name:$n, marketplace:null, status:"rejected", version:null, error:$e}' \
      >> "$_cc_nd" 2>/dev/null || true
  done

  mkdir -p "$CC_LEDGER_DIR"
  if jq -s '.' "$_cc_nd" > "${CC_LEDGER}.tmp" 2>/dev/null && [ -s "${CC_LEDGER}.tmp" ]; then
    mv "${CC_LEDGER}.tmp" "$CC_LEDGER"
    chown "${AGENT_USER}:${AGENT_USER}" "$CC_LEDGER_DIR" "$CC_LEDGER" 2>/dev/null || true
    log "claude plugin ledger written: ${CC_LEDGER} ($(jq -r '[.[]|select(.status=="installed")]|length' "$CC_LEDGER" 2>/dev/null || echo '?')/${#CC_REQ_NAME[@]} installed)"
  else
    rm -f "${CC_LEDGER}.tmp"
    log "WARN: could not write the Claude Code plugin ledger (${CC_LEDGER})"
  fi
  rm -f "$_cc_nd"
fi
