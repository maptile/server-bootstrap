# Description

A simple Shell script for bootstrapping an Ubuntu server environment.

# Compatibility

Currently tested only on Ubuntu 24.10. Other Debian-based systems may also work in theory, but the Docker installation flow in the script is written against Docker's official Ubuntu repository setup.

# Risk Notice

This script modifies system-level configuration including the hostname, `/etc/hosts`, users, `sudoers`, Docker, swap, and `/etc/fstab`. No guarantees are provided. Use it at your own risk.

It is better suited for a fresh machine and is not recommended for direct use on an existing production environment.

# Usage

```sh
wget -nv -O- https://raw.githubusercontent.com/maptile/server-bootstrap/refs/heads/main/install.sh | sudo bash /dev/stdin
```

When the script runs, all interaction happens once at the beginning:

1. It asks for the target hostname, defaulting to the current hostname.
2. It suggests a default swap size based on the current memory size and lets you override it.
3. It prompts you to paste SSH public keys, supporting multiple lines, and ends on an empty line.

After the installation steps begin, there will be no further interactive input in the middle of the process.

# `root` Login Scenario

If the server initially only allows `root` login and there is no `ubuntu` user yet, the script will automatically do the following:

1. Install `sudo` if it is not already present.
2. Create the `ubuntu` user.
3. Add `ubuntu` to the `sudo` group.
4. Write a passwordless sudo rule to `/etc/sudoers.d/90-server-bootstrap-ubuntu`.
5. Apply later user-level setup such as dotfiles, SSH public keys, and Docker group membership to the `ubuntu` account.

# SSH and Login Restrictions

The script writes the public keys you paste during installation into the target user's `~/.ssh/authorized_keys`.

After installation completes, it also downloads the following file into the target user's home directory:

```text
~/disable-root-login.sh
```

This script comes from:

```text
https://raw.githubusercontent.com/maptile/server-bootstrap/refs/heads/main/disable-root-login.sh
```

When needed, it updates `PermitRootLogin` and `PasswordAuthentication` in `sshd_config` to `no`, then restarts `sshd`.

It is recommended to confirm SSH public-key login works first, and then run it manually.

# Script Overview

The script first performs a basic system update and upgrade, then installs or configures the following components.

## Hostname

At the beginning of the installation, the script sets the system hostname based on your input. The default is the current hostname.

To avoid later `sudo` warnings caused by inconsistent hostname resolution, it also updates the hostname associated with `127.0.0.1` in `/etc/hosts`.

## System Tools

Installed via `apt`:

- `apt-transport-https`
- `ca-certificates`
- `curl`
- `git`
- `gpg-agent`
- `gnupg`
- `software-properties-common`
- `stow`
- `tmux`
- `vim`

## `dotfiles`

The script clones and enables this repository:

- <https://github.com/maptile/dotfiles.git>

By default it installs into `~/.dotfiles` under the target user's home directory, then applies it with `stow`.

## Docker

The script will:

1. Remove old Docker-related packages.
2. Add Docker's official Ubuntu repository and GPG key.
3. Install the following components:
   `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`
4. Add the target user to the `docker` group.

## BBR

The script will:

1. Write `net.core.default_qdisc=fq` and `net.ipv4.tcp_congestion_control=bbr` to `/etc/sysctl.d/999-custom-kernel-bbr.conf` if that file does not already exist.
2. Run `sysctl --system`.
3. Print the resulting BBR-related sysctl values.

## Swap

The script will:

1. Create `/swapfile1` based on your input.
2. Enable that swap file.
3. Write the persistent configuration to `/etc/fstab`.
4. Set `vm.swappiness` to `10`.

# Current Behavior Notes

Refer to the current [`install.sh`](/workspace/install.sh) as the source of truth.

The current script does not install the following items that were mentioned in older documentation:

- `snap core`
- `certbot`

# License

Released under the MIT License.
