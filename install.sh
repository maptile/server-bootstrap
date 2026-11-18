#!/usr/bin/env bash

set -euo pipefail

# Console colors for progress output.
GREEN='\033[0;32m'
NC='\033[0m'

BASE_PACKAGES=(ca-certificates curl git gnupg gpg-agent kmod mount procps stow sudo tmux vim)
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
DISTRIBUTION=''
DOCKER_URL=''
DOCKER_SUITE=''
DEFAULT_USER=''
TARGET_USER=''
TARGET_HOME=""
CURRENT_HOSTNAME=""
TARGET_HOSTNAME=""
SWAP_SIZE=""
SSH_KEYS_INPUT=""
HAS_TTY=false

log() {
    echo -e "${GREEN}$1${NC}"
}

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

# This bootstrap changes system state heavily, so it must run with root privileges.
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail 'Run this script with sudo or as root.'
    fi
}

detect_distribution() {
    local ID='' VERSION_CODENAME='' UBUNTU_CODENAME=''
    [ -r /etc/os-release ] || fail 'Cannot read /etc/os-release.'
    . /etc/os-release
    DISTRIBUTION="${ID}"

    case "${ID}" in
        debian)
            BASE_PACKAGES+=(locales)
            DOCKER_SUITE="${VERSION_CODENAME}"
            DEFAULT_USER='debian'
            ;;
        ubuntu)
            DOCKER_SUITE="${UBUNTU_CODENAME:-${VERSION_CODENAME}}"
            DEFAULT_USER='ubuntu'
            ;;
        *)
            fail "Unsupported distribution: ${ID:-unknown}. Use Debian or Ubuntu."
            ;;
    esac

    [ -n "${DOCKER_SUITE}" ] || fail "No release codename found for ${ID}."
    DOCKER_URL="https://download.docker.com/linux/${ID}"
    log "Detected ${ID} (${DOCKER_SUITE})"
}

select_target_user() {
    TARGET_USER="${SUDO_USER:-$(id -un)}"
    if [ "${TARGET_USER}" = 'root' ]; then
        TARGET_USER="${DEFAULT_USER}"
    fi
}

# A direct root login uses the distribution's default bootstrap account.
ensure_default_user() (
    local sudoers_file="/etc/sudoers.d/90-server-bootstrap-${DEFAULT_USER}"
    local rule="${DEFAULT_USER} ALL=(ALL) NOPASSWD:ALL" tmp_sudoers

    if ! id -u "${DEFAULT_USER}" >/dev/null 2>&1; then
        log "Creating ${DEFAULT_USER} user"
        useradd -m -s /bin/bash "${DEFAULT_USER}"
    fi
    usermod -aG sudo "${DEFAULT_USER}"

    if [ -f "${sudoers_file}" ] && [ "$(cat "${sudoers_file}")" = "${rule}" ]; then
        return
    fi

    log "Configuring passwordless sudo for ${DEFAULT_USER}"
    tmp_sudoers="$(mktemp "${sudoers_file}.XXXXXX")"
    trap 'rm -f -- "${tmp_sudoers}"' EXIT
    printf '%s\n' "${rule}" > "${tmp_sudoers}"
    chmod 0440 "${tmp_sudoers}"
    visudo -cf "${tmp_sudoers}"
    mv -f -- "${tmp_sudoers}" "${sudoers_file}"
)

prepare_target_user() {
    local entry
    if [ "${SUDO_USER:-root}" = 'root' ]; then
        ensure_default_user
    fi

    entry="$(getent passwd "${TARGET_USER}")" || fail "User ${TARGET_USER} not found."
    TARGET_HOME="$(cut -d: -f6 <<< "${entry}")"

    [ -d "${TARGET_HOME}" ] || fail "Home directory for ${TARGET_USER} not found."
}

# Run user-scoped commands with the target user's environment and HOME.
run_as_target_user() {
    sudo -H -u "${TARGET_USER}" -- "$@"
}

# Ask for the target hostname before any long-running changes start.
prompt_hostname() {
    local reply
    CURRENT_HOSTNAME="$(hostname)"

    if "${HAS_TTY}"; then
        printf "Enter hostname [%s]: " "${CURRENT_HOSTNAME}" >&3
        if read -r reply <&3 && [ -n "${reply}" ]; then
            TARGET_HOSTNAME="${reply}"
        else
            TARGET_HOSTNAME="${CURRENT_HOSTNAME}"
        fi
    else
        TARGET_HOSTNAME="${CURRENT_HOSTNAME}"
        printf "No interactive terminal detected, using current hostname: %s\n" "${TARGET_HOSTNAME}"
    fi
}

# Reuse active swap, or default to physical memory rounded to whole MiB.
detect_default_swap_size() {
    local mem_total_kb mem_total_mib
    if awk 'NR > 1 && $1 != "/swapfile1" {found = 1} END {exit !found}' /proc/swaps; then
        echo 0
        return
    fi
    mem_total_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    mem_total_mib="$(((mem_total_kb + 1023) / 1024))"
    echo "${mem_total_mib}M"
}

prompt_swap_size() {
    local default_swap_size reply
    default_swap_size="$(detect_default_swap_size)"

    if "${HAS_TTY}"; then
        printf "Enter swap size (for example 2G, 4096M, or 0 to skip) [%s]: " "${default_swap_size}" >&3
        if read -r reply <&3 && [ -n "${reply}" ]; then
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
    local line

    if ! "${HAS_TTY}"; then
        printf "No interactive terminal detected, skipping SSH public key input.\n"
        return
    fi

    printf "Paste SSH public keys for %s. Submit an empty line to finish.\n" "${TARGET_USER}" >&3
    while IFS= read -r line <&3 && [ -n "${line}" ]; do
        SSH_KEYS_INPUT+="${line}"$'\n'
    done
}

# After the bootstrap prompts finish, reattach stdin to the terminal so any later
# package-maintainer prompts can still receive key input even though the script was
# started via 'bash /dev/stdin'.
reattach_stdin_to_tty() {
    if "${HAS_TTY}"; then
        exec <&3 3>&-
    fi
}

# Install keys idempotently into authorized_keys for the target user.
install_ssh_keys() {
    if [ -z "${SSH_KEYS_INPUT}" ]; then
        log "No SSH public keys provided, skipping authorized_keys update"
        return
    fi

    log "Installing SSH public keys for ${TARGET_USER}"
    run_as_target_user bash -euc '
        umask 077
        install -d -m 0700 "${HOME}/.ssh"
        keys="${HOME}/.ssh/authorized_keys"
        touch "${keys}"
        chmod 0600 "${keys}"
        while IFS= read -r key_line; do
            [ -n "${key_line}" ] || continue
            if ! grep -Fqx -- "${key_line}" "${keys}"; then
                printf "%s\n" "${key_line}" >> "${keys}"
            fi
        done
    ' <<< "${SSH_KEYS_INPUT}"
}

# Keep /etc/hosts aligned with the chosen hostname so sudo does not warn about name resolution.
# Preserve aliases and comments when updating the machine's host entry.
sync_hosts_hostname() {
    local primary_ip target_ip tmp_hosts
    primary_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    target_ip=""

    if [ -n "${primary_ip}" ] && awk -v ip="${primary_ip}" '$1 == ip {found = 1} END {exit !found}' /etc/hosts; then
        target_ip="${primary_ip}"
    elif awk '$1 == "127.0.1.1" {found = 1} END {exit !found}' /etc/hosts; then
        target_ip='127.0.1.1'
    elif awk -v host="${CURRENT_HOSTNAME}" '$1 == "127.0.0.1" {for (i = 2; i <= NF && $i !~ /^#/; ++i) if ($i == host) found = 1} END {exit !found}' /etc/hosts; then
        target_ip='127.0.0.1'
    fi

    tmp_hosts="$(mktemp)"
    awk -v ip="${target_ip}" -v old="${CURRENT_HOSTNAME}" -v host="${TARGET_HOSTNAME}" '
        ip != "" && $1 == ip && !updated {
            names = ""
            found = 0
            for (i = 2; i <= NF && $i !~ /^#/; ++i) {
                name = $i
                if (name == old && name != "localhost") name = host
                if (name == host && found) continue
                if (name == host) found = 1
                names = names " " name
            }
            if (!found) names = names " " host
            comment = index($0, "#")
            print ip "\t" substr(names, 2) (comment ? " " substr($0, comment) : "")
            updated = 1
            next
        }
        {print}
        END {
            if (!updated) print "127.0.1.1\t" host
        }
    ' /etc/hosts > "${tmp_hosts}"
    if ! cmp -s "${tmp_hosts}" /etc/hosts; then
        cat "${tmp_hosts}" > /etc/hosts
    fi
    rm -f -- "${tmp_hosts}"
}

# Apply the requested hostname and persist it through the system hostname files.
configure_hostname() {
    [ "${TARGET_HOSTNAME}" != "${CURRENT_HOSTNAME}" ] || return 0
    log "Setting hostname to ${TARGET_HOSTNAME}"

    if [ -d /run/systemd/system ] && command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "${TARGET_HOSTNAME}"
    else
        hostname "${TARGET_HOSTNAME}"
        printf '%s\n' "${TARGET_HOSTNAME}" > /etc/hostname
    fi
}

configure_locale() {
    [ "${DISTRIBUTION}" = 'debian' ] || return 0

    log "Configuring en_US.UTF-8 locale"
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8
}

configure_docker_repository() (
    local arch tmp_dir
    arch="$(dpkg --print-architecture)"
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf -- "${tmp_dir}"' EXIT

    log "Configuring the Docker stable repository for ${DOCKER_SUITE}/${arch}"
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
        "${DOCKER_URL}/gpg" -o "${tmp_dir}/docker.asc"
    cat > "${tmp_dir}/docker.sources" <<EOF
Types: deb
URIs: ${DOCKER_URL}
Suites: ${DOCKER_SUITE}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
    install -m 0644 "${tmp_dir}/docker.asc" /etc/apt/keyrings/docker.asc
    install -m 0644 "${tmp_dir}/docker.sources" /etc/apt/sources.list.d/docker.sources
)

prepare_package_sources() {
    local legacy_source='/etc/apt/sources.list.d/docker.list'
    # APT cannot load the old and new entries together when their signing keys differ.
    if [ -f "${legacy_source}" ]; then
        log "Migrating ${legacy_source} to docker.sources"
        mv --backup=numbered -- "${legacy_source}" "${legacy_source}.disabled"
    fi

    if ! command -v curl >/dev/null 2>&1 || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
        apt-get update --error-on=any
        apt-get install -y ca-certificates curl
    fi
    configure_docker_repository
    apt-get update --error-on=any
}

install_docker() {
    local package
    local -a conflicts=()
    for package in docker docker-engine docker.io docker-compose docker-compose-v2 docker-doc \
        docker-buildx podman-docker containerd runc; do
        if [ "$(dpkg-query -W -f='${db:Status-Status}' "${package}" 2>/dev/null)" = installed ]; then
            conflicts+=("${package}-")
        fi
    done

    # Install Docker and remove conflicting packages in a single APT transaction.
    log "Installing Docker"
    apt-get install -y "${DOCKER_PACKAGES[@]}" "${conflicts[@]}"
    if ! getent group docker >/dev/null 2>&1; then
        groupadd docker
    fi
    usermod -aG docker "${TARGET_USER}"
}

install_dotfiles() {
    log "Installing dotfiles"
    run_as_target_user bash -euc '
        cd -- "${HOME}"
        if [ -d .dotfiles ]; then
            git -C .dotfiles pull --ff-only
        else
            git clone https://github.com/maptile/dotfiles.git .dotfiles
        fi
        cd .dotfiles
        stow .
    '
}

# Adjust the default Bash prompt so kitty sessions use color and the username
# segment uses cyan instead of green.
update_bashrc_prompt() {
    local bashrc_path
    bashrc_path="${TARGET_HOME}/.bashrc"

    if [ ! -f "${bashrc_path}" ]; then
        return
    fi

    run_as_target_user sed -i \
        -e 's/xterm-color|\*-256color) color_prompt=yes;;/xterm-color|xterm-kitty|*-256color) color_prompt=yes;;/' \
        -e 's/01;32m/01;36m/g' \
        -- "${bashrc_path}"
}

configure_bbr() {
    local config='/etc/sysctl.d/999-custom-kernel-bbr.conf'
    local algorithms='/proc/sys/net/ipv4/tcp_available_congestion_control'
    if [ ! -f "${config}" ]; then
        if ! grep -qw bbr "${algorithms}" 2>/dev/null; then
            modprobe tcp_bbr 2>/dev/null || true
        fi
        if ! grep -qw bbr "${algorithms}" 2>/dev/null; then
            log "BBR is unavailable on the running kernel, skipping BBR configuration"
            return
        fi
        log "Enabling BBR"
        sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr
        printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' > "${config}"
    fi
    sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control
}

create_swapfile() (
    local swapfile="$1" tmp_swap
    tmp_swap="$(mktemp "${swapfile}.XXXXXX")"
    trap 'rm -f -- "${tmp_swap}"' EXIT

    if [ "$(stat -f -c %T -- "${tmp_swap}")" = btrfs ]; then
        # Btrfs swap files require copy-on-write to be disabled before allocation.
        if ! command -v chattr >/dev/null 2>&1; then
            apt-get install -y e2fsprogs
        fi
        chattr +C "${tmp_swap}"
    fi
    fallocate -l "${SWAP_SIZE}" -- "${tmp_swap}"
    mkswap "${tmp_swap}"
    mv -T -- "${tmp_swap}" "${swapfile}"
)

configure_swap() {
    local swapfile='/swapfile1'
    local config='/etc/sysctl.d/999-custom-swappiness.conf'
    if [ "${SWAP_SIZE}" = 0 ]; then
        log "Skipping swapfile configuration"
        return
    fi

    log "Configuring swap"
    if [ ! -e "${swapfile}" ]; then
        create_swapfile "${swapfile}"
        if ! swapon "${swapfile}"; then
            rm -f -- "${swapfile}"
            fail "Could not activate ${swapfile}."
        fi
    elif ! awk -v file="${swapfile}" '$1 == file {found = 1} END {exit !found}' /proc/swaps; then
        swapon "${swapfile}"
    fi

    if ! awk -v file="${swapfile}" '$1 == file && $3 == "swap" {found = 1} END {exit !found}' /etc/fstab; then
        printf '\n%s none swap sw 0 0\n' "${swapfile}" >> /etc/fstab
    fi
    if [ ! -f "${config}" ]; then
        sysctl -w vm.swappiness=10
        printf '%s\n' 'vm.swappiness=10' > "${config}"
    fi
}

harden_ssh() (
    local config='/etc/ssh/sshd_config'
    local config_dir='/etc/ssh/sshd_config.d'
    local drop_in="${config_dir}/00-server-bootstrap.conf"
    local temp_dir effective
    local restore_config=false reload_attempted=false

    if ! command -v sshd >/dev/null 2>&1; then
        log 'OpenSSH server is not installed, skipping SSH hardening'
        return
    fi
    [ -f "${config}" ] || fail "OpenSSH configuration not found: ${config}"
    sshd -t -f "${config}"
    mkdir -p -- "${config_dir}"
    temp_dir="$(mktemp -d "${config_dir}/.server-bootstrap.XXXXXX")"

    # Roll back the drop-in if validation or reloading fails.
    trap '
        if "${restore_config}"; then
            if [ -e "${temp_dir}/previous" ] || [ -L "${temp_dir}/previous" ]; then
                mv -T -- "${temp_dir}/previous" "${drop_in}" ||
                    fail "Could not restore the SSH configuration from ${temp_dir}/previous."
            else
                rm -f -- "${drop_in}" || fail "Could not remove ${drop_in}."
            fi
            if "${reload_attempted}" && ! systemctl reload ssh.service; then
                printf "%s\n" "Original SSH configuration was restored on disk, but reloading it failed." >&2
            fi
        fi
        rm -rf -- "${temp_dir}"
    ' EXIT

    if [ -e "${drop_in}" ] || [ -L "${drop_in}" ]; then
        cp -a -- "${drop_in}" "${temp_dir}/previous"
    fi
    printf '%s\n' 'PermitRootLogin no' 'PasswordAuthentication no' > "${temp_dir}/new"
    chmod 0644 "${temp_dir}/new"
    restore_config=true
    mv -T -- "${temp_dir}/new" "${drop_in}"

    sshd -t -f "${config}"
    effective="$(sshd -T -f "${config}")"
    if ! grep -Fxq 'permitrootlogin no' <<< "${effective}" ||
        ! grep -Fxq 'passwordauthentication no' <<< "${effective}"; then
        fail "OpenSSH did not apply both settings from ${drop_in}. Check Include and option precedence."
    fi

    # A daemon started later, including through ssh.socket, reads the new configuration.
    if systemctl is-active --quiet ssh.service 2>/dev/null; then
        reload_attempted=true
        systemctl reload ssh.service || fail 'Could not reload ssh.service.'
    fi
    restore_config=false
    log "SSH settings applied through ${drop_in}"
)

[ "$#" -eq 0 ] || fail 'Run install.sh without arguments.'
require_root
export PATH="/usr/local/sbin:/usr/sbin:/sbin:${PATH}"
detect_distribution
exec 9>/run/lock/server-bootstrap.lock
flock -n 9 || fail 'Another server bootstrap is running.'
select_target_user
if { exec 3<>/dev/tty; } 2>/dev/null; then
    HAS_TTY=true
fi
prompt_hostname
prompt_swap_size
prompt_ssh_keys
reattach_stdin_to_tty

log "Using target user: ${TARGET_USER}"
log "Using hostname: ${TARGET_HOSTNAME}"
log "Using swap size: ${SWAP_SIZE}"

prepare_package_sources
log "Upgrading base system"
apt-get -y upgrade
log "Installing common dependencies"
apt-get install -y "${BASE_PACKAGES[@]}"
configure_locale
log "Removing unused components"
apt-get -y autoremove

prepare_target_user
configure_hostname
sync_hosts_hostname
install_ssh_keys
install_docker
log "Installed package versions"
dpkg-query -W -f='${Package}\t${Version}\n' "${BASE_PACKAGES[@]}" "${DOCKER_PACKAGES[@]}"

install_dotfiles
update_bashrc_prompt
configure_bbr
configure_swap
harden_ssh

echo -e "${GREEN}
DONE.
Open a new login session as ${TARGET_USER} to run Docker commands without sudo.${NC}"
