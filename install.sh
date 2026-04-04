#!/usr/bin/env bash

set -euo pipefail

# Console colors for progress output.
GREEN='\033[0;32m'
NC='\033[0m'

# Repository-hosted helper script downloaded near the end of bootstrap.
DISABLE_ROOT_LOGIN_SCRIPT_URL='https://raw.githubusercontent.com/maptile/server-bootstrap/refs/heads/main/disable-root-login.sh'

# The script may start as root, but user-level assets should end up under the target user.
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
TARGET_HOME=""
TARGET_HOSTNAME=""
SWAP_SIZE=""
SSH_KEYS_INPUT=""

log() {
    echo -e "${GREEN}$1${NC}"
}

# This bootstrap changes system state heavily, so it must run with root privileges.
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Please run this script with sudo or as root."
        exit 1
    fi
}

# Some minimal images do not ship with sudo.
ensure_sudo_installed() {
    if ! command -v sudo >/dev/null 2>&1; then
        log "Installing sudo"
        apt-get update
        apt-get install -y sudo
    fi
}

# When the machine only has root access, create the conventional ubuntu user
# and grant passwordless sudo so the rest of the setup can target that account.
ensure_ubuntu_user() {
    if ! id -u ubuntu >/dev/null 2>&1; then
        log "Creating ubuntu user"
        useradd -m -s /bin/bash ubuntu
    fi

    usermod -aG sudo ubuntu

    local sudoers_file='/etc/sudoers.d/90-server-bootstrap-ubuntu'
    if [ ! -f "${sudoers_file}" ] || ! grep -q '^ubuntu ALL=(ALL) NOPASSWD:ALL$' "${sudoers_file}" 2>/dev/null; then
        log "Configuring passwordless sudo for ubuntu"
        echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > "${sudoers_file}"
        chmod 0440 "${sudoers_file}"
    fi
}

# Resolve which user should own home-directory changes.
prepare_target_user() {
    require_root

    if [ "$(id -un)" = 'root' ] && [ "${TARGET_USER}" = 'root' ]; then
        ensure_sudo_installed
        ensure_ubuntu_user
        TARGET_USER='ubuntu'
    fi

    TARGET_HOME="$(eval echo "~${TARGET_USER}")"

    if [ ! -d "${TARGET_HOME}" ]; then
        echo "Home directory for ${TARGET_USER} not found."
        exit 1
    fi
}

# Run user-scoped commands with the target user's environment and HOME.
run_as_target_user() {
    sudo -H -u "${TARGET_USER}" bash -lc "$1"
}

# Ask for the target hostname before any long-running changes start.
prompt_hostname() {
    local current_hostname reply
    current_hostname="$(hostname)"

    if [ -r /dev/tty ]; then
        printf "Enter hostname [%s]: " "${current_hostname}" > /dev/tty
        if read -r reply < /dev/tty && [ -n "${reply}" ]; then
            TARGET_HOSTNAME="${reply}"
        else
            TARGET_HOSTNAME="${current_hostname}"
        fi
    else
        TARGET_HOSTNAME="${current_hostname}"
        printf "No interactive terminal detected, using current hostname: %s\n" "${TARGET_HOSTNAME}"
    fi
}

# Default swap size matches physical memory, rounded to whole MiB.
detect_default_swap_size() {
    local mem_total_kb mem_total_mib
    mem_total_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    mem_total_mib="$(((mem_total_kb + 1023) / 1024))"
    echo "${mem_total_mib}M"
}

# Ask for swap size before making any irreversible system changes.
prompt_swap_size() {
    local default_swap_size reply
    default_swap_size="$(detect_default_swap_size)"

    if [ -r /dev/tty ]; then
        printf "Detected memory size: %s\n" "${default_swap_size}" > /dev/tty
        printf "Enter swap size (for example 2G, 4096M) [%s]: " "${default_swap_size}" > /dev/tty
        if read -r reply < /dev/tty && [ -n "${reply}" ]; then
            SWAP_SIZE="${reply}"
        else
            SWAP_SIZE="${default_swap_size}"
        fi
    else
        SWAP_SIZE="${default_swap_size}"
        printf "No interactive terminal detected, using default swap size: %s\n" "${SWAP_SIZE}"
    fi
}

# Allow the operator to paste one or more SSH public keys, ending with a blank line.
prompt_ssh_keys() {
    local line first_line=1

    if [ ! -r /dev/tty ]; then
        printf "No interactive terminal detected, skipping SSH public key input.\n"
        return
    fi

    printf "Paste SSH public keys for %s. Submit an empty line to finish.\n" "${TARGET_USER}" > /dev/tty

    while true; do
        if ! IFS= read -r line < /dev/tty; then
            break
        fi

        if [ -z "${line}" ]; then
            break
        fi

        if [ ${first_line} -eq 1 ]; then
            SSH_KEYS_INPUT="${line}"
            first_line=0
        else
            SSH_KEYS_INPUT="${SSH_KEYS_INPUT}
${line}"
        fi
    done
}

# After the bootstrap prompts finish, reattach stdin to the terminal so any later
# package-maintainer prompts can still receive key input even though the script was
# started via 'bash /dev/stdin'.
reattach_stdin_to_tty() {
    if [ ! -t 0 ] && [ -r /dev/tty ]; then
        exec </dev/tty
    fi
}

# Install keys idempotently into authorized_keys for the target user.
install_ssh_keys() {
    if [ -z "${SSH_KEYS_INPUT}" ]; then
        log "No SSH public keys provided, skipping authorized_keys update"
        return
    fi

    log "Installing SSH public keys for ${TARGET_USER}"
    install -d -m 0700 -o "${TARGET_USER}" -g "${TARGET_USER}" "${TARGET_HOME}/.ssh"
    touch "${TARGET_HOME}/.ssh/authorized_keys"
    chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.ssh/authorized_keys"
    chmod 0600 "${TARGET_HOME}/.ssh/authorized_keys"

    while IFS= read -r key_line; do
        [ -n "${key_line}" ] || continue
        if ! grep -Fqx "${key_line}" "${TARGET_HOME}/.ssh/authorized_keys"; then
            printf '%s\n' "${key_line}" >> "${TARGET_HOME}/.ssh/authorized_keys"
        fi
    done <<__SSH_KEYS__
${SSH_KEYS_INPUT}
__SSH_KEYS__
}

# Keep /etc/hosts aligned with the chosen hostname so sudo does not warn about name resolution.
# Update the existing host entry for the machine IP instead of appending a new hostname.
sync_hosts_hostname() {
    local current_hostname desired_hostname primary_ip target_ip tmp_hosts
    current_hostname="$(hostname)"
    desired_hostname="${TARGET_HOSTNAME}"
    primary_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    target_ip=""

    if [ -n "${primary_ip}" ] && awk -v ip="${primary_ip}" '$1 == ip {found = 1} END {exit !found}' /etc/hosts; then
        target_ip="${primary_ip}"
    elif awk '$1 == "127.0.1.1" {found = 1} END {exit !found}' /etc/hosts; then
        target_ip='127.0.1.1'
    elif awk -v host="${current_hostname}" '$1 == "127.0.0.1" {for (i = 2; i <= NF; ++i) if ($i == host) found = 1} END {exit !found}' /etc/hosts; then
        target_ip='127.0.0.1'
    fi

    if [ -z "${target_ip}" ]; then
        return
    fi

    tmp_hosts="$(mktemp)"
    awk -v ip="${target_ip}" -v host="${desired_hostname}" '
        $1 == ip {
            if (ip == "127.0.0.1") {
                print ip, "localhost", host
            } else {
                print ip, host
            }
            next
        }
        {print}
    ' /etc/hosts > "${tmp_hosts}"
    cat "${tmp_hosts}" > /etc/hosts
    rm -f "${tmp_hosts}"
}

# Apply the requested hostname and persist it through the system hostname files.
configure_hostname() {
    log "Setting hostname to ${TARGET_HOSTNAME}"

    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "${TARGET_HOSTNAME}"
    else
        echo "${TARGET_HOSTNAME}" > /etc/hostname
        hostname "${TARGET_HOSTNAME}"
    fi
}

# Retry the Docker GPG key download until it succeeds or the operator aborts.
download_docker_gpg_key() {
    local gpg_tmp
    gpg_tmp="$(mktemp)"

    while true; do
        if curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o "${gpg_tmp}"; then
            install -m 0644 "${gpg_tmp}" /etc/apt/keyrings/docker.gpg
            rm -f "${gpg_tmp}"
            return
        fi

        rm -f "${gpg_tmp}"
        log "Docker GPG download failed, retrying in 1 second. Press Ctrl+C to abort."
        sleep 1
        gpg_tmp="$(mktemp)"
    done
}

# Keep the SSH hardening helper as a standalone file in the user's home directory.
download_disable_root_login_script() {
    log "Downloading disable-root-login.sh for ${TARGET_USER}"
    curl -fsSL "${DISABLE_ROOT_LOGIN_SCRIPT_URL}" -o "${TARGET_HOME}/disable-root-login.sh"
    chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/disable-root-login.sh"
    chmod +x "${TARGET_HOME}/disable-root-login.sh"
}

# Adjust the default Bash prompt so kitty sessions use color and the username
# segment uses cyan instead of green.
update_bashrc_prompt() {
    local bashrc_path
    bashrc_path="${TARGET_HOME}/.bashrc"

    if [ ! -f "${bashrc_path}" ]; then
        return
    fi

    sed -i         -e 's/xterm-color|\*-256color) color_prompt=yes;;/xterm-color|xterm-kitty|*-256color) color_prompt=yes;;/'         -e 's/01;32m/01;36m/g'         "${bashrc_path}"

    chown "${TARGET_USER}:${TARGET_USER}" "${bashrc_path}"
}

prepare_target_user
prompt_hostname
prompt_swap_size
prompt_ssh_keys
reattach_stdin_to_tty
sync_hosts_hostname
install_ssh_keys

log "Using target user: ${TARGET_USER}"
log "Using hostname: ${TARGET_HOSTNAME}"
log "Using swap size: ${SWAP_SIZE}"

log "Changing to home directory"
cd "${TARGET_HOME}"

configure_hostname

# Bring the base system up to date first.
log "Upgrading base system"
apt-get -y update
apt-get -y upgrade

# Install the base toolchain needed by this bootstrap.
log "Installing common dependencies"
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    git \
    gpg-agent \
    gnupg \
    software-properties-common \
    stow \
    tmux \
    vim

log "Remove unused components"
apt-get -y autoremove

# Clone and apply the author's dotfiles for the target user.
log "Install dotfiles"
run_as_target_user "
cd '${TARGET_HOME}'
if [ ! -d ./.dotfiles ]; then
    git clone https://github.com/maptile/dotfiles.git ./.dotfiles
else
    git -C ./.dotfiles pull --ff-only
fi
cd ./.dotfiles
stow .
"

# Replace any distro-provided Docker packages with Docker's official packages.
log "Installing docker"
DOCKER_OLD_PACKAGES=()
for pkg in docker docker-engine docker.io containerd runc; do
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
        DOCKER_OLD_PACKAGES+=("${pkg}")
    fi
done
if [ ${#DOCKER_OLD_PACKAGES[@]} -gt 0 ]; then
    apt-get remove -y "${DOCKER_OLD_PACKAGES[@]}"
fi

install -m 0755 -d /etc/apt/keyrings
download_docker_gpg_key
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update

apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

if ! getent group docker >/dev/null 2>&1; then
    groupadd docker
fi
usermod -aG docker "${TARGET_USER}"

# Enable BBR if the custom sysctl file does not already exist.
log "Enabling BBR"
if [ ! -f /etc/sysctl.d/999-custom-kernel-bbr.conf ]; then
    echo 'net.core.default_qdisc=fq' | tee -a /etc/sysctl.d/999-custom-kernel-bbr.conf
    echo 'net.ipv4.tcp_congestion_control=bbr' | tee -a /etc/sysctl.d/999-custom-kernel-bbr.conf
    sysctl --system
fi

log "Enabling BBR result"
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_congestion_control

# Leave an existing swapfile alone on reruns.
log "Configuring swap"
if [ -e /swapfile1 ]; then
    log "Swapfile already exists, skipping swap configuration"
else
    fallocate -l "${SWAP_SIZE}" /swapfile1
    chown root:root /swapfile1
    chmod 0600 /swapfile1
    mkswap /swapfile1
    swapon /swapfile1

    if [ ! -f /etc/sysctl.d/999-custom-swappiness.conf ]; then
        echo 'vm.swappiness=10' | tee -a /etc/sysctl.d/999-custom-swappiness.conf
    fi

    if ! grep -q '/swapfile1 none swap sw 0 0' /etc/fstab; then
        sed -i '$ a\
/swapfile1 none swap sw 0 0\
' /etc/fstab
    fi
fi

update_bashrc_prompt
download_disable_root_login_script

echo -e "${GREEN}
DONE.
Please consider more steps:
* review and run ${TARGET_HOME}/disable-root-login.sh after confirming SSH key login works
* logout and login as ${TARGET_USER}, then you can run docker commands without sudo${NC}"
