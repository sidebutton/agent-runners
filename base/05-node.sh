# 05-node.sh — Node.js 22 + pnpm.

step "Step 5/16: Node.js 22 + pnpm"
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install "${APT_OPTS[@]}" nodejs
fi
npm install -g pnpm >/dev/null
log "node: $(node --version)  npm: $(npm --version)  pnpm: $(pnpm --version)"
