#!/usr/bin/env bash
#
# ==============================================================================
# Script Name : vps-setup.sh
# Repository  : vps-bootstrap
# Description : Original lightweight baseline setup script used for rapid VPS
#               preparation prior to deploying VPN servers and client tools.
# Author      : DevOps Engineering Portfolio Project
# License     : MIT
# ==============================================================================

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/vps_setup.log"
readonly SSH_CONFIG="/etc/ssh/sshd_config"
readonly SUDOERS_FILE="/etc/sudoers.d/90-nopasswd"
readonly FAIL2BAN_CONFIG="/etc/fail2ban/jail.local"

export DEBIAN_FRONTEND=noninteractive

log_info()  { echo -e "[INFO]  $(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "[WARN]  $(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') - $1" >&2 | tee -a "$LOG_FILE"; }

check_environment() {
    log_info "Executing pre-flight checks..."
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script requires root privileges. Execute with: sudo bash $SCRIPT_NAME"
        exit 1
    fi

    if [[ ! -f /etc/os-release ]]; then
        log_error "/etc/os-release not detected. Target platform is unsupported."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    case "$ID" in
        ubuntu|debian)
            log_info "Target platform validated: $PRETTY_NAME ($ID - $VERSION_CODENAME)"
            ;;
        *)
            log_error "Unsupported Linux distribution: '$ID'. Only Debian and Ubuntu are supported."
            exit 1
            ;;
    esac
}

install_base_packages() {
    log_info "Refreshing APT package repositories and applying security upgrades..."
    apt-get update -y
    apt-get upgrade -y

    log_info "Installing core system utilities..."
    local base_packages=(
        sudo
        ufw
        fail2ban
        python3-systemd
        htop
        curl
        wget
        nano
        net-tools
        zip
        rsync
        apt-transport-https
        ca-certificates
        mtr-tiny
        traceroute
        gnupg
        lsb-release
    )

    apt-get install -y "${base_packages[@]}"
    log_info "Base packages installed successfully."
}

setup_users_and_groups() {
    log_info "Configuring RBAC groups..."
    local groups=("vpn-users" "ssh-users" "sftp-users")
    for group in "${groups[@]}"; do
        if getent group "$group" >/dev/null 2>&1; then
            log_info "Group '$group' already exists. Skipping."
        else
            groupadd "$group"
            log_info "Created security group: '$group'"
        fi
    done

    log_info "Provisioning system users..."
    local shell_users=("ssh_user" "vpn_user")
    for user in "${shell_users[@]}"; do
        if id "$user" >/dev/null 2>&1; then
            log_info "User '$user' already exists. Skipping creation."
        else
            adduser --gecos "" --disabled-password "$user"
            log_info "Created standard user: '$user'"
            echo "--- Set password for $user ---"
            passwd "$user"
        fi
    done

    if id "sftp_user" >/dev/null 2>&1; then
        log_info "User 'sftp_user' already exists. Skipping creation."
    else
        adduser --gecos "" --shell /usr/sbin/nologin --disabled-password sftp_user
        log_info "Created SFTP-only user 'sftp_user' with non-interactive shell."
        echo "--- Set password for sftp_user ---"
        passwd sftp_user
    fi

    echo "--- Set password for root user ---"
    passwd root

    usermod -aG vpn-users,ssh-users,sudo ssh_user
    usermod -aG vpn-users,ssh-users,sudo vpn_user
    usermod -aG sftp-users sftp_user
    log_info "User groups and administrative assignments updated."
}

configure_sftp_chroot() {
    log_info "Applying SFTP directory ownership and isolation permissions..."
    chown root:root /home/sftp_user
    chmod 755 /home/sftp_user

    mkdir -p /home/sftp_user/upload
    chown sftp_user:sftp-users /home/sftp_user/upload
    chmod 775 /home/sftp_user/upload
    log_info "SFTP Chroot directory layout verified (/home/sftp_user/upload)."
}

configure_sudoers() {
    log_info "Configuring passwordless sudo access for group '%sudo'..."
    cp /etc/sudoers "/etc/sudoers.bak.$(date +%F-%T)"

    cat > "$SUDOERS_FILE" <<'EOF'
%sudo ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 440 "$SUDOERS_FILE"

    if ! visudo -c; then
        log_error "Syntax validation failed for $SUDOERS_FILE. Removing file to prevent lockout."
        rm -f "$SUDOERS_FILE"
        exit 1
    fi
    log_info "Sudoers syntax validated successfully."
}

configure_ssh() {
    log_info "Configuring OpenSSH daemon settings..."
    cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.$(date +%F-%T)"

    if grep -q "^Port" "$SSH_CONFIG"; then
        sed -i 's/^Port.*/Port 30222/' "$SSH_CONFIG"
    elif grep -q "^#Port" "$SSH_CONFIG"; then
        sed -i 's/^#Port.*/Port 30222/' "$SSH_CONFIG"
    else
        echo "Port 30222" >> "$SSH_CONFIG"
    fi

    if grep -q "^PermitRootLogin" "$SSH_CONFIG"; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "$SSH_CONFIG"
    else
        echo "PermitRootLogin yes" >> "$SSH_CONFIG"
    fi

    if grep -q "^PasswordAuthentication" "$SSH_CONFIG"; then
        sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CONFIG"
    else
        echo "PasswordAuthentication yes" >> "$SSH_CONFIG"
    fi

    if ! grep -q "Match Group sftp-users" "$SSH_CONFIG"; then
        cat <<'EOL' >> "$SSH_CONFIG"

Match Group sftp-users
    ChrootDirectory /home/%u
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    AllowAgentForwarding no
EOL
    fi

    if ! sshd -t; then
        log_error "SSHD configuration validation failed. Reverting from backup."
        exit 1
    fi

    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        log_warn "Ubuntu systemd socket activation detected (ssh.socket). Migrating to standard service unit..."
        systemctl stop ssh.socket
        systemctl disable ssh.socket
    fi

    if systemctl list-unit-files | grep -q "^ssh\.service"; then
        systemctl enable ssh.service
        systemctl restart ssh.service
    else
        systemctl enable sshd.service
        systemctl restart sshd.service
    fi

    log_info "SSH service successfully hardened and restarted on port 30222."
}

configure_firewall() {
    log_info "Configuring Uncomplicated Firewall (UFW)..."
    ufw default deny incoming
    ufw default allow outgoing

    ufw allow 80 comment 'HTTP'
    ufw allow 443 comment 'HTTPS'
    ufw allow 53 comment 'DNS'
    ufw allow 30222 comment 'Custom SSH'

    ufw allow 30301 comment 'VPN service port 1'
    ufw allow 30302 comment 'VPN service port 2'
    ufw allow 30303 comment 'VPN service port 3'

    ufw --force enable
    log_info "UFW active and rules committed."
}

configure_fail2ban() {
    log_info "Configuring Fail2Ban intrusion prevention..."
    cat > "$FAIL2BAN_CONFIG" <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = 30222
backend = systemd
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    log_info "Fail2Ban service active and monitoring SSH on port 30222."
}

install_docker() {
    local install_compose=""
    read -r -p "Do you want to install Docker and Docker Compose? (y/n): " install_compose
    if [[ "$install_compose" =~ ^[Yy]$ ]]; then
        log_info "Preparing official Docker CE repository installation..."
        # shellcheck disable=SC1091
        source /etc/os-release
        local os_id="${ID}"
        local distro_codename="${VERSION_CODENAME:-$(lsb_release -cs)}"

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
          https://download.docker.com/linux/${os_id} \
          ${distro_codename} stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        systemctl enable docker
        systemctl start docker
        log_info "Docker CE & Compose Plugin installed and service enabled."
    else
        log_info "Skipping Docker installation."
    fi
}

main() {
    log_info "Starting baseline setup execution..."
    check_environment
    install_base_packages
    setup_users_and_groups
    configure_sftp_chroot
    configure_sudoers
    configure_ssh
    configure_firewall
    configure_fail2ban
    install_docker
    log_info "VPS baseline setup execution complete. Review log at: $LOG_FILE"
}

main "$@"