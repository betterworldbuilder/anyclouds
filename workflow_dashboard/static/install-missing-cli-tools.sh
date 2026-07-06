#!/usr/bin/env bash
set -euo pipefail

RESULT_FILE="${RESULT_FILE:-/tmp/preflight-install-results.json}"
TOOLS=("$@")

if [ "${#TOOLS[@]}" -eq 0 ]; then
  echo "No tools requested."
  exit 0
fi

# ── sudo helper ────────────────────────────────────────────────────────────
# Pipes password from SUDO_PASS_FILE to sudo -S on every call.
# IMPORTANT: Never pipe a remote script directly to _sudo bash — download
# to a tmpfile first so the password pipe and the script pipe don't conflict.
_sudo() {
  if [ -n "${SUDO_PASS_FILE:-}" ] && [ -f "$SUDO_PASS_FILE" ]; then
    cat "$SUDO_PASS_FILE" | sudo -S -p '' "$@" 2>/dev/null
  else
    sudo "$@"
  fi
}

# ── OS check ────────────────────────────────────────────────────────────────
if [ ! -f /etc/os-release ]; then
  echo "Unsupported OS: missing /etc/os-release"
  exit 1
fi
. /etc/os-release
if [ "${ID:-}" != "ubuntu" ] && [ "${ID:-}" != "debian" ]; then
  echo "Unsupported OS for auto-install: ${ID:-unknown}"
  echo "Automatic install supports Ubuntu/Debian only."
  for t in "${TOOLS[@]}"; do echo "  - $t (manual install required)"; done
  exit 1
fi

echo "OS: ${PRETTY_NAME:-$ID}"
echo "Tools requested: ${TOOLS[*]}"
echo ""

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ── Validate sudo access ───────────────────────────────────────────────────
echo "Validating sudo access..."
if ! _sudo true; then
  echo "[ERROR] sudo authentication failed. Check your password."
  exit 1
fi
echo "sudo OK."
echo ""

echo "Updating apt..."
_sudo apt-get update -qq

# ── Installers ──────────────────────────────────────────────────────────────
install_git() {
  _sudo apt-get install -y git
}

install_curl() {
  _sudo apt-get install -y curl
}

install_jq() {
  _sudo apt-get install -y jq
}

install_openstack() {
  # Install via apt (python3-openstackclient) — most reliable on Ubuntu/Debian
  _sudo apt-get install -y python3-openstackclient
}

install_kubectl() {
  echo "Fetching latest kubectl version..."
  local VER
  VER=$(curl -sL https://dl.k8s.io/release/stable.txt)
  echo "kubectl version: $VER"
  curl -sLo /tmp/kubectl "https://dl.k8s.io/release/${VER}/bin/linux/amd64/kubectl"
  _sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
}

install_flux() {
  # Download script to tmpfile first — do NOT pipe curl directly to _sudo bash
  # because the password pipe and the script pipe would conflict for stdin
  local TMP
  TMP=$(mktemp /tmp/flux_install_XXXXXX.sh)
  echo "Downloading flux install script..."
  curl -s -o "$TMP" https://fluxcd.io/install.sh
  chmod +x "$TMP"
  _sudo bash "$TMP"
  rm -f "$TMP"
}

install_helm() {
  # Download and extract manually so _sudo only runs for the final mv
  # The official get-helm-3 script calls sudo internally which breaks _sudo
  echo "Fetching latest helm version..."
  local VER
  VER=$(curl -s https://api.github.com/repos/helm/helm/releases/latest 2>/dev/null \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4)
  VER="${VER:-v3.17.0}"
  echo "helm version: $VER"
  curl -sL "https://get.helm.sh/helm-${VER}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp
  _sudo mv /tmp/linux-amd64/helm /usr/local/bin/helm
  _sudo chmod +x /usr/local/bin/helm
  rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
}

install_yq() {
  _sudo wget -qO /usr/local/bin/yq \
    https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  _sudo chmod +x /usr/local/bin/yq
}

install_kustomize() {
  # Download and extract manually — the official install script calls sudo internally
  echo "Fetching latest kustomize version..."
  local VER
  VER=$(curl -s https://api.github.com/repos/kubernetes-sigs/kustomize/releases/latest 2>/dev/null \
    | grep '"tag_name"' | grep 'kustomize/' | head -1 | cut -d'"' -f4)
  VER="${VER:-kustomize/v5.4.3}"
  local VER_NUM="${VER#kustomize/}"
  echo "kustomize version: $VER_NUM"
  curl -sL "https://github.com/kubernetes-sigs/kustomize/releases/download/${VER}/kustomize_${VER_NUM}_linux_amd64.tar.gz" \
    -o /tmp/kustomize.tar.gz
  tar -xzf /tmp/kustomize.tar.gz -C /tmp
  _sudo mv /tmp/kustomize /usr/local/bin/kustomize
  _sudo chmod +x /usr/local/bin/kustomize
  rm -f /tmp/kustomize.tar.gz
}

install_opencenter() {
  if has_cmd opencenter; then return 0; fi
  if [ -z "${OPENCENTER_INSTALL_URL:-}" ]; then
    echo "OpenCenter CLI missing and OPENCENTER_INSTALL_URL is not set."
    echo "Manual setup required:"
    echo "  git clone https://github.com/opencenter-cloud/openCenter-cli.git"
    echo "  cd openCenter-cli && mise trust && mise install && mise run build"
    echo "  sudo cp ./bin/opencenter /usr/local/bin/opencenter"
    return 2
  fi
  local TMP
  TMP=$(mktemp /tmp/opencenter_install_XXXXXX.sh)
  curl -fsSL "$OPENCENTER_INSTALL_URL" -o "$TMP"
  chmod +x "$TMP"
  _sudo bash "$TMP"
  rm -f "$TMP"
}

# ── Main loop ───────────────────────────────────────────────────────────────
FAILED=0
INSTALLED=()
SKIPPED=()
FAILED_TOOLS=()

for tool in "${TOOLS[@]}"; do
  echo ""
  echo "── $tool ──────────────────────────"

  if has_cmd "$tool"; then
    echo "$tool already installed: $(command -v "$tool")"
    SKIPPED+=("$tool")
    continue
  fi

  echo "Installing $tool..."
  set +e
  case "$tool" in
    git)        install_git ;;
    curl)       install_curl ;;
    jq)         install_jq ;;
    openstack)  install_openstack ;;
    kubectl)    install_kubectl ;;
    flux)       install_flux ;;
    helm)       install_helm ;;
    yq)         install_yq ;;
    kustomize)  install_kustomize ;;
    opencenter) install_opencenter || { FAILED_TOOLS+=("$tool"); FAILED=1; continue; } ;;
    *)
      echo "Unknown tool: $tool"
      FAILED_TOOLS+=("$tool")
      FAILED=1
      continue
      ;;
  esac
  local_rc=$?
  set -e

  if [ $local_rc -eq 0 ] && has_cmd "$tool"; then
    echo "$tool installed: $(command -v "$tool")"
    INSTALLED+=("$tool")
  else
    echo "FAILED: $tool"
    FAILED_TOOLS+=("$tool")
    FAILED=1
  fi
done

echo ""
echo "═══════════════════════════════════"
echo "Install Summary"
echo "═══════════════════════════════════"
[ ${#INSTALLED[@]}    -gt 0 ] && echo "Installed:  ${INSTALLED[*]}"
[ ${#SKIPPED[@]}      -gt 0 ] && echo "Skipped:    ${SKIPPED[*]}"
[ ${#FAILED_TOOLS[@]} -gt 0 ] && echo "Failed:     ${FAILED_TOOLS[*]}"

jq -n \
  --argjson ins "$(printf '%s\n' "${INSTALLED[@]+"${INSTALLED[@]}"}" | jq -Rsc 'split("\n")|map(select(length>0))')" \
  --argjson sk  "$(printf '%s\n' "${SKIPPED[@]+"${SKIPPED[@]}"}"  | jq -Rsc 'split("\n")|map(select(length>0))')" \
  --argjson fl  "$(printf '%s\n' "${FAILED_TOOLS[@]+"${FAILED_TOOLS[@]}"}" | jq -Rsc 'split("\n")|map(select(length>0))')" \
  '{"installed":$ins,"skipped":$sk,"failed":$fl}' > "$RESULT_FILE" 2>/dev/null || true

echo "Results: $RESULT_FILE"
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
