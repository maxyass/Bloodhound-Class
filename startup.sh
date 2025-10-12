#!/usr/bin/env bash
set -euo pipefail

# install-bloodhound-ce.sh
# Official install method for BloodHound Community Edition (CE)
# https://github.com/SpecterOps/bloodhound-cli

ARCH="amd64"
CLI_VERSION="latest"
CLI_BINARY="bloodhound-cli-linux-${ARCH}"
CLI_ARCHIVE="${CLI_BINARY}.tar.gz"
DOWNLOAD_URL="https://github.com/SpecterOps/bloodhound-cli/releases/latest/download/${CLI_ARCHIVE}"

# Check for root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (e.g. sudo ./install-bloodhound-ce.sh)"
  exit 1
fi

echo "[*] Installing prerequisites: Docker and Docker Compose plugin..."
apt-get update -y
apt-get install -y \
  docker.io docker-compose-plugin \
  curl wget tar

echo "[*] Enabling and starting Docker..."
systemctl enable --now docker

# Optional: add your non-root user to docker group
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  echo "[*] Adding user '${SUDO_USER}' to docker group..."
  usermod -aG docker "${SUDO_USER}" || true
  echo "[!] You must log out and back in for group changes to take effect."
fi

echo "[*] Downloading bloodhound-cli..."
cd /tmp
wget -q --show-progress "${DOWNLOAD_URL}"

echo "[*] Extracting CLI..."
tar -xzf "${CLI_ARCHIVE}"
chmod +x bloodhound-cli
mv bloodhound-cli /usr/local/bin/bloodhound-cli

echo "[*] Installing BloodHound CE using bloodhound-cli..."
bloodhound-cli install

echo
echo "[✅] BloodHound CE installation complete!"
echo "    Access the web UI at: http://localhost:8080/ui/login"
echo "    To get your password again, run:"
echo "        bloodhound-cli config get default_password"
echo
echo "    To reset the password later:"
echo "        bloodhound-cli resetpwd"
echo

