#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_USER="${SUDO_USER:-$USER}"
APP_UID="$(id -u "${APP_USER}")"
VENV_PYTHON="${PROJECT_DIR}/.venv/bin/python"
SYSTEMD_DIR="/etc/systemd/system"

if [[ ! -x "${VENV_PYTHON}" ]]; then
  echo "Missing venv python: ${VENV_PYTHON}"
  echo "Create/install dependencies first."
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/install_boot_services.sh"
  exit 1
fi

install_unit() {
  local src="$1"
  local dst="$2"
  sed \
    -e "s|__PROJECT_DIR__|${PROJECT_DIR}|g" \
    -e "s|__VENV_PYTHON__|${VENV_PYTHON}|g" \
    -e "s|__APP_USER__|${APP_USER}|g" \
    -e "s|__APP_UID__|${APP_UID}|g" \
    "${src}" > "${dst}"
}

install_unit "${PROJECT_DIR}/deploy/systemd/turret-tracker.service" "${SYSTEMD_DIR}/turret-tracker.service"
install_unit "${PROJECT_DIR}/deploy/systemd/turret-api.service" "${SYSTEMD_DIR}/turret-api.service"

systemctl daemon-reload
systemctl enable turret-tracker.service turret-api.service
systemctl restart turret-tracker.service turret-api.service

echo "Installed and started:"
echo "  turret-tracker.service"
echo "  turret-api.service"
echo
echo "Check status:"
echo "  sudo systemctl status turret-tracker.service --no-pager"
echo "  sudo systemctl status turret-api.service --no-pager"
