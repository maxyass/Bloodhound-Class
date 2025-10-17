#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ---------------------------
# Pre-installation checks
# ---------------------------

echo "[*] Pre-installation check starting..."

# Ensure running as root early
if [ "$EUID" -ne 0 ]; then
  echo "[-] This script must be run as root. Use: sudo $0"
  exit 1
fi

# 什 Step 1: Clean up APT and fix broken states
echo "[*] Cleaning APT cache and updating package lists..."
apt clean
apt update

echo "[*] Attempting to fix broken packages (if any)..."
if ! apt --fix-broken install -y; then
  echo "[!] Failed to fix broken dependencies. Manual intervention may be required."
  exit 1
fi

#  Step 2: Ensure required packages are installed
REQUIRED_PACKAGES=(
  python3
  python3-venv
  python3-pip
  unzip
  curl
  default-jre
  )

echo "[*] Ensuring required packages are installed..."
for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "[✔] $pkg already installed"
  else
    echo "[*] Installing $pkg..."
    if ! apt install -y "$pkg"; then
      echo "[✘] Failed to install $pkg. Aborting."
      exit 1
    fi
  fi
done

#  Optional: Check Python version compatibility (compare to 3.13.7 per your check)
echo "[*] Checking Python version compatibility..."
if ! command -v python3 >/dev/null 2>&1; then
  echo "[!] python3 not found after installing packages. Aborting."
  exit 1
fi

PY_VERSION_RAW="$(python3 --version 2>&1 | awk '{print $2}')"
PY_VERSION="${PY_VERSION_RAW:-0.0.0}"

# Use dpkg --compare-versions if available, else fallback to sort -V comparison
MIN_PY="3.12.7"
PY_OK=1
if command -v dpkg >/dev/null 2>&1; then
  if dpkg --compare-versions "$PY_VERSION" ge "$MIN_PY"; then
    PY_OK=0
  else
    PY_OK=1
  fi
else
  # fallback: lexicographic version compare using sort -V
  if [ "$(printf '%s\n%s\n' "$MIN_PY" "$PY_VERSION" | sort -V | head -n1)" = "$MIN_PY" ] && [ "$PY_VERSION" != "$MIN_PY" ]; then
    # $MIN_PY is smaller -> $PY_VERSION is greater => OK
    PY_OK=0
  elif [ "$PY_VERSION" = "$MIN_PY" ]; then
    PY_OK=0
  else
    PY_OK=1
  fi
fi

if [ "$PY_OK" -ne 0 ]; then
  echo "[!] python3 version is ${PY_VERSION} but python3-venv requires ${MIN_PY}."
  echo "    You may need to wait for package updates or manually upgrade python3."
  exit 1
fi

echo "[✔] All pre-installation checks passed."
echo

# ---------------------------
# Existing installer script
# ---------------------------

# install-bloodhound-ce.sh
# Installs Docker (CE preferred) + Compose plugin (v2), bloodhound-cli, and runs bloodhound-cli install
# Captures the admin password and writes it to 'bloodhound_admin_creds'
# Tested for Kali/Debian-like systems; maps "kali-rolling" -> "bookworm" for Docker repo compatibility.

COMPOSE_V2_VERSION="v2.20.2"   # change if you want a specific compose v2 release
BH_CLI_ARCH="amd64"            # change to arm64 if needed

# --- Helpers ---
err() { echo "[ERROR] $*" >&2; }
info() { echo "[*] $*"; }

info "Updating apt repositories..."
apt update -y

info "Installing required base packages..."
apt install -y --no-install-recommends \
  apt-transport-https ca-certificates curl gnupg2 lsb-release wget tar

# --- Configure Docker official repo (robust for Kali) ---
info "Configuring Docker APT repository (robust for Kali)..."
ARCH=$(dpkg --print-architecture)
install -d -m0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Determine codename mapping
LSB_CODENAME=$(lsb_release -cs 2>/dev/null || echo "kali-rolling")
case "$LSB_CODENAME" in
  kali-rolling) DOCKER_DISTRO="bookworm" ;;
  trixie|bookworm|bullseye|buster) DOCKER_DISTRO="$LSB_CODENAME" ;;
  *) DOCKER_DISTRO="bookworm" ;;
esac
info "Using Docker repo distribution codename: ${DOCKER_DISTRO}"

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${DOCKER_DISTRO} stable
EOF

info "Updating apt with Docker repo..."
apt update -y || { err "apt update failed after adding Docker repo"; }

# --- Install Docker (prefer docker-ce) ---
if apt-cache policy docker-ce >/dev/null 2>&1; then
  info "Attempting to install docker-ce and docker-compose-plugin from Docker repo..."
  if apt-get install -y --no-install-recommends docker-ce docker-compose-plugin; then
    info "Installed docker-ce and docker-compose-plugin"
  else
    err "docker-ce install failed; falling back to docker.io"
    apt-get install -y docker.io
  fi
else
  info "docker-ce not present in apt cache; installing docker.io from distro repos"
  apt-get install -y docker.io
fi

# Ensure Docker daemon is enabled and running
info "Checking if Docker service is active..."

if ! systemctl is-active --quiet docker; then
  info "Starting Docker service..."
  systemctl enable docker
  systemctl start docker

  # Wait a few seconds to let the daemon start
  sleep 3
fi

# Double-check Docker is up
if ! docker info >/dev/null 2>&1; then
  err "Docker daemon failed to start or is not responding. Aborting."
  exit 1
fi

info "Docker service is active and responding."

# --- Ensure 'docker compose' command is available (Compose v2) ---
if docker compose version >/dev/null 2>&1; then
  info "docker compose (v2) is available"
else
  info "docker compose (v2) not found — installing Compose v2 CLI plugin binary to /usr/libexec/docker/cli-plugins ..."
  mkdir -p /usr/libexec/docker/cli-plugins
  COMPOSE_BIN_PATH="/usr/libexec/docker/cli-plugins/docker-compose"
  curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_V2_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
    -o "${COMPOSE_BIN_PATH}"
  chmod +x "${COMPOSE_BIN_PATH}"
  info "Installed docker compose plugin to ${COMPOSE_BIN_PATH}"
fi

# Quick verify
if ! docker compose version >/dev/null 2>&1; then
  err "docker compose is still not available. Please check installation. 'docker --version' and 'docker compose version' for diagnostics."
  docker --version || true
  exit 1
fi

# --- Optional: add invoking non-root sudo user to docker group ---
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  info "Adding ${SUDO_USER} to the docker group (so they can run docker without sudo)..."
  usermod -aG docker "${SUDO_USER}" || true
  info "User ${SUDO_USER} added to docker group. They must log out and back in (or run 'newgrp docker' in their shell) for the change to take effect."
fi

# --- Install bloodhound-cli ---
info "Downloading bloodhound-cli (arch=${BH_CLI_ARCH})..."
cd /tmp
BH_ARCHIVE="bloodhound-cli-linux-${BH_CLI_ARCH}.tar.gz"
BH_URL="https://github.com/SpecterOps/bloodhound-cli/releases/latest/download/${BH_ARCHIVE}"

# Try download (fail with message if no network)
if curl -fsSL -o "${BH_ARCHIVE}" "${BH_URL}"; then
  info "Downloaded ${BH_ARCHIVE}"
else
  err "Failed to download bloodhound-cli from ${BH_URL}. Check internet connectivity."
  exit 1
fi

info "Extracting and installing bloodhound-cli..."
tar -xzf "${BH_ARCHIVE}"
chmod +x bloodhound-cli
mv -f bloodhound-cli /usr/local/bin/bloodhound-cli
info "bloodhound-cli installed to /usr/local/bin/bloodhound-cli"

# --- Run bloodhound-cli install and capture output to parse password ---
info "Running 'bloodhound-cli install' to deploy BloodHound CE via Docker Compose..."
TMP_LOG="$(mktemp /tmp/bh_install_log.XXXXXX)"
# Run install, stream to console, and tee into temp log
# Note: bloodhound-cli can be interactive; running as root here to ensure containers/volumes created successfully.
bloodhound-cli install 2>&1 | tee "${TMP_LOG}"

# --- Extract admin password from installer output and save it to the invoking user's Desktop ---
info "Attempting to parse the admin password from installer output..."

# Typical installer line:
# [+] You can log in as `admin` with this password: 1WBhSFbPTurX1xBrUPUky5eqxv4wtZ26
ADMIN_PW="$(grep -i 'password' "${TMP_LOG}" | tail -n1 | sed -E 's/.*[Pp]assword[: ]*//; s/^[[:space:]]*//; s/[[:space:]]*$//')"

# Fallback: try bloodhound-cli config get default_password
if [ -z "${ADMIN_PW:-}" ]; then
  info "Could not parse password from log — trying 'bloodhound-cli config get default_password'..."
  ADMIN_PW="$(bloodhound-cli config get default_password 2>/dev/null || true)"
  ADMIN_PW="$(echo "${ADMIN_PW}" | tr -d '\r\n')"
fi

# Determine the invoking user's home directory (works when run with sudo)
if [ -n "${SUDO_USER:-}" ]; then
  INVOKING_USER="${SUDO_USER}"
  USER_HOME="$(getent passwd "$INVOKING_USER" | cut -d: -f6 || true)"
fi
# Fallbacks if above didn't yield a home
USER_HOME="${USER_HOME:-${HOME:-}}"

# If we still don't have a home directory, fallback to current directory
if [ -z "${USER_HOME}" ]; then
  info "Could not determine a desktop path for the invoking user; writing to current directory instead."
  DESKTOP_PATH="${PWD}/bloodhound_admin_creds"
else
  DESKTOP_DIR="${USER_HOME}/Desktop"
  mkdir -p "${DESKTOP_DIR}" 2>/dev/null || true
  DESKTOP_PATH="${DESKTOP_DIR}/bloodhound_admin_creds"
fi

if [ -n "${ADMIN_PW:-}" ]; then
  echo "${ADMIN_PW}" > "${DESKTOP_PATH}"
  info "Admin password written to: ${DESKTOP_PATH}"
else
  err "Failed to determine the admin password automatically. No file written."
  err "You can try retrieving it manually with: bloodhound-cli config get default_password"
fi

# cleanup temp log if you want to remove it; keep for debugging
info "Installer output saved to: ${TMP_LOG}"
info "BloodHound CLI finished. Access the UI at: http://localhost:8080/ui/login"
info "To retrieve the admin password later: bloodhound-cli config get default_password"
info "To reset the password later: bloodhound-cli resetpwd"

echo
echo "-----------------------------"
echo "Notes:"
echo "- If the user '${SUDO_USER:-root}' was added to the docker group, open a new shell or run: newgrp docker"
echo "- For GUI logins you must log out and back in to apply group membership changes."
echo "- If you want the password file written to a different location, edit the script or tell me which path to use."
echo "-----------------------------"

