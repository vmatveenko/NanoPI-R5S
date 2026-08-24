#!/bin/bash
# Install or uninstall NanoPi Manager.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="/usr/local/lib/nanopi-manager"
STATE_DIR="/var/lib/nanopi-manager"
CONFIG_DIR="/etc/nanopi-manager"
RELEASE_REPO="vmatveenko/NanoPI-R5S"
MANAGER_UNITS=(
  nanopi-manager-agent.service
  nanopi-manager-web.service
  nanopi-manager-policy.service
  nanopi-manager-policy.timer
)

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/install-manager.sh [install]
  sudo ./scripts/install-manager.sh uninstall

Команда install используется по умолчанию.
EOF
}

if [ "${EUID}" -ne 0 ]; then
  echo "Запустите от root: sudo $0" >&2
  exit 1
fi

COMMAND="${1:-install}"
case "$COMMAND" in
  install) ;;
  uninstall)
    systemctl disable --now nanopi-manager-policy.timer nanopi-manager-web.service nanopi-manager-agent.service 2>/dev/null || true
    for unit in nanopi-manager-policy.timer nanopi-manager-policy.service nanopi-manager-web.service nanopi-manager-agent.service; do
      rm -f -- "/etc/systemd/system/$unit"
    done
    rm -f -- /run/nanopi-manager/agent.sock
    rm -rf -- "$INSTALL_DIR"
    systemctl daemon-reload
    echo "NanoPi Manager удалён."
    echo "Сетевые настройки, данные 3x-ui, резервные копии и $STATE_DIR сохранены."
    exit 0
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

case "$(uname -m)" in
  aarch64|arm64) RELEASE_ARCH="arm64" ;;
  x86_64|amd64) RELEASE_ARCH="amd64" ;;
  *) echo "Неподдерживаемая архитектура: $(uname -m)" >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl nftables isc-dhcp-server iproute2 ethtool tar

getent group nanopi-manager >/dev/null || groupadd --system nanopi-manager
if ! id nanopi-manager >/dev/null 2>&1; then
  useradd --system --gid nanopi-manager --home-dir "$STATE_DIR" --shell /usr/sbin/nologin nanopi-manager
fi
install -d -o root -g nanopi-manager -m 0750 "$INSTALL_DIR"
install -d -o nanopi-manager -g nanopi-manager -m 0700 "$STATE_DIR"
install -d -o root -g nanopi-manager -m 0750 "$CONFIG_DIR"

WEB_SOURCE="${NANOPI_MANAGER_WEB_BINARY:-}"
AGENT_SOURCE="${NANOPI_MANAGER_AGENT_BINARY:-}"

build_from_source() {
  if ! command -v go >/dev/null 2>&1; then
    apt-get install -y golang-go
  fi
  BUILD_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$BUILD_DIR"' EXIT
  (
    cd "$REPO_DIR/manager"
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$BUILD_DIR/nanopi-manager-web" ./cmd/nanopi-manager-web
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$BUILD_DIR/nanopi-manager-agent" ./cmd/nanopi-manager-agent
  )
  WEB_SOURCE="$BUILD_DIR/nanopi-manager-web"
  AGENT_SOURCE="$BUILD_DIR/nanopi-manager-agent"
}

download_release() {
  VERSION="${NANOPI_MANAGER_VERSION:-latest}"
  if [ "$VERSION" = "latest" ]; then
    BASE_URL="https://github.com/${RELEASE_REPO}/releases/latest/download"
  else
    BASE_URL="https://github.com/${RELEASE_REPO}/releases/download/${VERSION}"
  fi
  DOWNLOAD_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$DOWNLOAD_DIR"' EXIT
  curl -fL "$BASE_URL/nanopi-manager-linux-${RELEASE_ARCH}.tar.gz" -o "$DOWNLOAD_DIR/manager.tar.gz"
  tar -xzf "$DOWNLOAD_DIR/manager.tar.gz" -C "$DOWNLOAD_DIR"
  WEB_SOURCE="$DOWNLOAD_DIR/nanopi-manager-web"
  AGENT_SOURCE="$DOWNLOAD_DIR/nanopi-manager-agent"
}

if [ -z "$WEB_SOURCE" ] && [ -x "$REPO_DIR/manager/dist/linux-${RELEASE_ARCH}/nanopi-manager-web" ]; then
  WEB_SOURCE="$REPO_DIR/manager/dist/linux-${RELEASE_ARCH}/nanopi-manager-web"
  AGENT_SOURCE="$REPO_DIR/manager/dist/linux-${RELEASE_ARCH}/nanopi-manager-agent"
elif [ -z "$WEB_SOURCE" ] && [ "${NANOPI_MANAGER_BUILD_FROM_SOURCE:-0}" = "1" ]; then
  build_from_source
elif [ -z "$WEB_SOURCE" ]; then
  download_release
fi

test -f "$WEB_SOURCE" && test -f "$AGENT_SOURCE"
install -o root -g root -m 0755 "$WEB_SOURCE" "$INSTALL_DIR/nanopi-manager-web"
install -o root -g root -m 0755 "$AGENT_SOURCE" "$INSTALL_DIR/nanopi-manager-agent"

# A mask left by an earlier installation or manual recovery overrides copied
# unit files and makes systemctl enable --now fail. Remove persistent and
# runtime masks before installing fresh units.
systemctl unmask "${MANAGER_UNITS[@]}" >/dev/null 2>&1 || true
systemctl unmask --runtime "${MANAGER_UNITS[@]}" >/dev/null 2>&1 || true

install -o root -g root -m 0644 "$REPO_DIR/manager/packaging/systemd/nanopi-manager-agent.service" /etc/systemd/system/
install -o root -g root -m 0644 "$REPO_DIR/manager/packaging/systemd/nanopi-manager-web.service" /etc/systemd/system/
install -o root -g root -m 0644 "$REPO_DIR/manager/packaging/systemd/nanopi-manager-policy.service" /etc/systemd/system/
install -o root -g root -m 0644 "$REPO_DIR/manager/packaging/systemd/nanopi-manager-policy.timer" /etc/systemd/system/

if [ ! -f "$CONFIG_DIR/manager.env" ]; then
  install -o root -g nanopi-manager -m 0640 "$REPO_DIR/manager/packaging/config/manager.env" "$CONFIG_DIR/manager.env"
fi

systemctl daemon-reload
systemctl enable --now nanopi-manager-agent.service nanopi-manager-web.service nanopi-manager-policy.timer

PORT="$(sed -n 's/^NANOPI_MANAGER_PORT=//p' "$CONFIG_DIR/manager.env" | tail -1)"
PORT="${PORT:-8080}"
echo
echo "NanoPi Manager установлен."
echo "Откройте: http://<IP-устройства>:${PORT}"
echo "При первом входе задайте логин и пароль администратора."
