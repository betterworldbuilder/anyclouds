#!/usr/bin/env bash
set -euo pipefail

RESULT_FILE="${RESULT_FILE:-/tmp/preflight-install-results.json}"
TOOLS=("$@")

if [ "${#TOOLS[@]}" -eq 0 ]; then
  echo "No tools requested."
  exit 0
fi

# ── sudo helper ────────────────────────────────────────────────────────────
# Each call pipes the password from SUDO_PASS_FILE via sudo -S.
# This avoids needing a TTY and works in non-interactive SSE subprocesses.
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

# ── Validate sudo access before touching anything ──────────────────────────
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
  curl -s https://fluxcd.io/install.sh | _sudo bash
}

install_helm() {
  curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

install_yq() {
  _sudo wget -qO /usr/local/bin/yq \
    https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  _sudo chmod +x /usr/local/bin/yq
}

install_kustomize() {
  curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
  _sudo mv kustomize /usr/local/bin/kustomize
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
  curl -fsSL "$OPENCENTER_INSTALL_URL" | _sudo bash
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
