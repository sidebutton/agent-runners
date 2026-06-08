# components/postgres-client/install.sh — PostgreSQL client (psql).
#
# Sourced by base/run.sh when `postgres-client` is in AGENT_COMPONENTS. Runs as
# root at provision time. Idempotent.

step "Component: PostgreSQL client"
if command -v psql >/dev/null 2>&1; then
  log "psql already installed: $(psql --version 2>/dev/null)"
else
  apt-get install "${APT_OPTS[@]}" postgresql-client || log "WARN: postgresql-client install failed"
  log "psql: $(psql --version 2>/dev/null || echo not-installed)"
fi
