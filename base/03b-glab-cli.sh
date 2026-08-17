# 03b-glab-cli.sh — GitLab CLI (glab).
#
# Twin of 03-gh-cli.sh: glab is installed UNCONDITIONALLY on every agent, exactly
# like gh, so a freshly provisioned box has the GitLab CLI on PATH out of the box
# instead of waiting for an in-repo setup script to install it at boot (SCRUM-1958).
# Not modelled as an optional component on purpose — no AGENT_COMPONENTS entry, no
# SKIP_*/INSTALL_* gate — so it must never grow one without revisiting that ruling.
#
# INSTALL ONLY. No `glab auth login`, no credential helper, no GITLAB_TOKEN read:
# a fresh instance must come up with glab present and NO GitLab connection
# configured. Auth is conditional on GITLAB_TOKEN at boot and owned by a separate
# step (SCRUM-1952) — adding it here would bake a credential into the golden image.
#
# Why a pinned release .deb instead of 03's apt-repo idiom: gitlab-org/cli ships no
# apt repo, and pinning is what makes the golden image reproducible — the same
# provision run twice installs the same bytes. The sha256 turns a corrupted or
# tampered download into a hard fail instead of a bad binary on every agent.
# Bumping = edit GLAB_VERSION + BOTH checksums, taken from that release's
# checksums.txt (same maintenance class as CCR_VERSION in the CCR component):
#   https://gitlab.com/gitlab-org/cli/-/releases/v<VERSION>/downloads/checksums.txt

step "Step 3b/16: GitLab CLI"

GLAB_VERSION="1.113.0"
GLAB_SHA256_AMD64="80928175a2d66c6262c8303aeee9dd5c5a67dafc03668c8b073a495110f9af02"
GLAB_SHA256_ARM64="5a3f3d3211e2de1a7cff6884345509ac569d7b4e627749d162b8aa559ab0a0de"

if ! command -v glab >/dev/null 2>&1; then
  glab_arch="$(dpkg --print-architecture)"
  case "$glab_arch" in
    amd64) glab_sha="$GLAB_SHA256_AMD64" ;;
    arm64) glab_sha="$GLAB_SHA256_ARM64" ;;
    # Die rather than WARN-and-continue: nothing later self-heals a glab-less box
    # (the boot-time install is GITLAB_TOKEN-gated), so continuing would bake a
    # silently glab-less "green" image. Pin a checksum for the new arch to fix.
    *) die "glab: unsupported architecture '$glab_arch' (pinned for amd64, arm64)" ;;
  esac

  glab_deb="/tmp/glab_${GLAB_VERSION}_linux_${glab_arch}.deb"
  # 03's flags, but NOT its --max-time 120: that bounds a ~2 KB keyring, whereas
  # this asset is ~18 MB and a 120 s cap would hard-fail (and abort the provision)
  # on any link slower than ~150 KB/s. Bound the failure mode that actually
  # matters instead — a STALLED transfer: give up only if throughput stays under
  # 1 KB/s for 30 s, with a generous absolute backstop. Same intent as 06's
  # per-read `wget --timeout=30` on the (larger) Chrome .deb.
  curl -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 30 \
    --max-time 600 --retry 3 --retry-connrefused \
    -o "$glab_deb" \
    "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${glab_arch}.deb"

  glab_got="$(sha256sum "$glab_deb" | cut -d' ' -f1)"
  if [ "$glab_got" != "$glab_sha" ]; then
    rm -f "$glab_deb"
    die "glab: checksum mismatch for $glab_arch (expected $glab_sha, got $glab_got)"
  fi

  # Single static binary + man pages; no maintainer scripts and no services, so
  # nothing here starts or enables anything. `apt-get install <file>` rather than
  # `dpkg -i` because the package declares `Depends: git` — already satisfied by
  # 02-system.sh, but apt resolves it instead of leaving a half-configured dpkg
  # state if that ever changes.
  apt-get install "${APT_OPTS[@]}" "$glab_deb"
  rm -f "$glab_deb"
fi
log "glab: $(glab --version | head -1)"
