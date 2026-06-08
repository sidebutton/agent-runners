# components/docker/install.sh — Docker engine (rootful).
#
# Sourced by base/run.sh when `docker` is in AGENT_COMPONENTS. Runs as root at
# provision time. Installs Docker CE from Docker's apt repo, enables the daemon,
# and adds the agent user to the `docker` group so it can run containers without
# sudo (required by Testcontainers-based test suites). Idempotent.
#
# Security note: membership in the `docker` group is root-equivalent on the box —
# acceptable for a dedicated build/test agent; surfaced in the wizard helper text.

step "Component: Docker"
if command -v docker >/dev/null 2>&1; then
  log "docker already installed: $(docker --version 2>/dev/null)"
else
  install -m 0755 -d /etc/apt/keyrings
  if curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 --retry-connrefused \
       https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; then
    chmod a+r /etc/apt/keyrings/docker.asc
    UBU_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBU_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install "${APT_OPTS[@]}" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      || log "WARN: docker-ce install failed"
  else
    log "WARN: could not fetch Docker apt key — Docker not installed"
  fi
fi

systemctl enable --now docker >/dev/null 2>&1 || log "WARN: could not enable/start docker.service"
usermod -aG docker "$AGENT_USER" 2>/dev/null || log "WARN: usermod -aG docker ${AGENT_USER} failed"
if id -nG "$AGENT_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  log "docker: $(docker --version 2>/dev/null || echo not-installed) — ${AGENT_USER} in docker group"
else
  log "docker: $(docker --version 2>/dev/null || echo not-installed) — WARN: ${AGENT_USER} NOT in docker group"
fi
