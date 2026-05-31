# 03-gh-cli.sh — GitHub CLI.

step "Step 3/16: GitHub CLI"
if ! command -v gh >/dev/null 2>&1; then
  curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 --retry-connrefused https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
  arch="$(dpkg --print-architecture)"
  echo "deb [arch=${arch} signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
  apt-get install "${APT_OPTS[@]}" gh
fi
log "gh: $(gh --version | head -1)"
