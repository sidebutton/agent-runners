# 05-node.sh — Node.js 22 + pnpm.

step "Step 5/16: Node.js 22 + pnpm"
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 --retry-connrefused https://deb.nodesource.com/setup_22.x | bash -
  apt-get install "${APT_OPTS[@]}" nodejs
fi
# Bound npm registry fetches so a stalled connection retries/fails instead of
# hanging the install (Hetzner fsn1 network). Applies to the `npm install -g`
# calls in this step and 07/08 — all run as root at install time.
npm config set fetch-timeout 120000 >/dev/null 2>&1 || true
npm config set fetch-retries 5 >/dev/null 2>&1 || true
npm install -g pnpm >/dev/null
log "node: $(node --version)  npm: $(npm --version)  pnpm: $(pnpm --version)"
