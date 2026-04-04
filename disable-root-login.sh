#!/usr/bin/env bash

set -euo pipefail

SSHD_CONFIG='/etc/ssh/sshd_config'

if [ ! -f "${SSHD_CONFIG}" ]; then
    echo 'sshd_config not found.'
    exit 1
fi

ensure_sshd_option() {
    local key="$1"
    local desired="$2"

    if grep -Eq "^[[:space:]]*${key}[[:space:]]+${desired}([[:space:]]+.*)?$" "${SSHD_CONFIG}"; then
        echo "${key} already set to ${desired}."
        return
    fi

    if grep -Eq "^[[:space:]]*${key}[[:space:]]+" "${SSHD_CONFIG}"; then
        sudo sed -i -E "0,/^[[:space:]]*${key}[[:space:]]+.*/s//${key} ${desired}/" "${SSHD_CONFIG}"
        echo "Updated ${key} to ${desired}."
    else
        echo "${key} ${desired}" | sudo tee -a "${SSHD_CONFIG}" > /dev/null
        echo "Appended ${key} ${desired}."
    fi
}

ensure_sshd_option 'PermitRootLogin' 'no'
ensure_sshd_option 'PasswordAuthentication' 'no'

sudo sshd -t
sudo systemctl restart sshd.service

echo 'sshd_config updated and sshd restarted.'
