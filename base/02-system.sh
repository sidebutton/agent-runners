# 02-system.sh — apt update, upgrade, and essential packages.

step "Step 1/16: System update"
apt-get update -qq
apt-get upgrade "${APT_OPTS[@]}"

step "Step 2/16: Essential packages"
apt-get install "${APT_OPTS[@]}" \
  curl wget git unzip zip jq build-essential \
  ca-certificates gnupg lsb-release \
  software-properties-common apt-transport-https \
  openssh-client net-tools nano htop tmux tree \
  python3 python3-pip python3-venv \
  ripgrep fd-find xclip bc imagemagick xdotool
