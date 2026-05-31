# 01-preflight.sh — privilege check, env validation, OS detection, apt defaults.
# Sourced by base/run.sh. Exits the installer (via die) on any precondition
# that would make a clean run impossible.

if [ "$(id -u)" -ne 0 ]; then
  die "must run as root (curl … | sudo bash)"
fi

AGENT_TOKEN="${AGENT_TOKEN:-}"
AGENT_NAME="${AGENT_NAME:-}"
AGENT_ROLE="${AGENT_ROLE:-se}"
PORTAL_URL="${PORTAL_URL:-https://sidebutton.com}"

if [ -z "$AGENT_TOKEN" ]; then
  die "AGENT_TOKEN is required (get one from $PORTAL_URL/portal/agents)"
fi
if [ -z "$AGENT_NAME" ]; then
  die "AGENT_NAME is required (unique fleet identifier, e.g. 'venmate-se-1')"
fi
case "$AGENT_ROLE" in
  se|qa|sd) ;;
  *) log "WARN: AGENT_ROLE='${AGENT_ROLE}' not in {se,qa,sd}; continuing" ;;
esac

AGENT_PASSWORD="${AGENT_PASSWORD:-$(head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)}"

export AGENT_TOKEN AGENT_NAME AGENT_ROLE PORTAL_URL AGENT_PASSWORD

log "AGENT_NAME=${AGENT_NAME}"
log "AGENT_ROLE=${AGENT_ROLE}"
log "AGENT_RUNNER=${AGENT_RUNNER:-unset}"
log "PORTAL_URL=${PORTAL_URL}"

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VER="${VERSION_ID:-unknown}"
  if [ "$OS_ID" = "ubuntu" ] && [ "$OS_VER" = "24.04" ]; then
    log "OS: Ubuntu 24.04 (supported)"
  else
    log "WARN: detected ${OS_ID} ${OS_VER}; this script targets Ubuntu 24.04 — continuing on best-effort"
  fi
else
  log "WARN: /etc/os-release not readable — continuing on best-effort"
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

if [ -d /etc/needrestart/conf.d ]; then
  echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/50-autorestart.conf
fi

# Bound apt's network ops so a slow/stalled mirror can't hang the whole install.
# (Observed: a Hetzner fsn1 CX23 sat at flat ~0.6% CPU for 18+ min, blocked in
# `apt-get update` with no timeout, never reaching service start.) Written as a
# global apt config so it also covers the bare `apt-get update` calls that don't
# go through APT_OPTS.
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/80-sidebutton-timeouts <<'EOF'
Acquire::Retries "3";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
EOF
