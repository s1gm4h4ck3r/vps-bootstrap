#!/usr/bin/env bash
#
# ==============================================================================
# Script Name : vps-bootstrap.sh
# Repository  : vps-bootstrap
# Description : Automated baseline provisioning, security hardening, user access
#               management, and system initialization for Debian (11/12) and
#               Ubuntu (20.04/22.04/24.04 LTS) VPS compute instances.
# Author      : DevOps Engineering Portfolio Project
# License     : MIT
# ==============================================================================

# ------------------------------------------------------------------------------
# Shell Safety Directives (Defensive Bash)
# ------------------------------------------------------------------------------
# -e : Exit immediately if any command returns a non-zero exit status.
# -u : Treat unset variables as errors and exit immediately.
# -o pipefail : Prevent errors in piped commands from being masked.
set -euo pipefail

# ——————————————————————————————————————————————————————————————————————————————
# Global Constants & Environment Configuration
# ——————————————————————————————————————————————————————————————————————————————
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/vps_bootstrap.log"
readonly SSH_CONFIG="/etc/ssh/sshd_config"
readonly SUDOERS_FILE="/etc/sudoers.d/90-nopasswd"
readonly FAIL2BAN_CONFIG="/etc/fail2ban/jail.local"
readonly SSH_PORT=30222

# Suppress interactive dialog prompts during APT operations
export DEBIAN_FRONTEND=noninteractive

# ——————————————————————————————————————————————————————————————————————————————
# Logging Subsystem
# ——————————————————————————————————————————————————————————————————————————————
log_info() {
    echo -e "[INFO]  $(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "[WARN]  $(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') - $1" >&2 | tee -a "$LOG_FILE"
}

# ——————————————————————————————————————————————————————————————————————————————
# Step 1: Pre-flight Validations & Clock Synchronization
# ——————————————————————————————————————————————————————————————————————————————
check_environment() {
    log_info "Executing pre-flight checks..."

    # Enforce execution by effective root (EUID 0)
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script requires root privileges. Execute with: sudo bash $SCRIPT_NAME"
        exit 1
    fi

    # Confirm availability of standard os-release database
    if [[ ! -f /etc/os-release ]]; then
        log_error "/etc/os-release not detected. Target platform is unsupported."
        exit 1
    fi

    # Source os-release variables and validate distribution
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

    # Enforce UTC timezone standard and enable NTP synchronization
    log_info "Configuring system clock and UTC timezone..."
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone UTC || log_warn "Unable to set UTC timezone via timedatectl."
        timedatectl set-ntp true || log_warn "Unable to enable NTP via timedatectl."
    fi
}

# ——————————————————————————————————————————————————————————————————————————————
# Step 2: System Upgrades and Base Tooling
# ——————————————————————————————————————————————————————————————————————————————
install_base_packages() {
    log_info "Refreshing APT package repositories and applying security upgrades..."
    apt-get update -y
    apt-get upgrade -y

    log_info "Installing core system utilities and security dependencies..."
    # Array breakdown:
    # - sudo: Required on minimal Debian installations.
    # - ufw, fail2ban: Host firewall and automated brute-force protection.
    # - python3-systemd: Ingests journald logs into Fail2Ban without auth.log.
    # - System triage tools: htop, curl, wget, rsync, net-tools, etc.
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

    # Validate that sudo binary exists and is executable
    if ! command -v sudo >/dev/null 2>&1; then
        log_error "Failed to locate 'sudo' binary after installation. Aborting."
        exit 1
    fi

    log_info "Base packages installed and verified successfully."
}

# ——————————————————————————————————————————————————————————————————————————————
# Step 3: Identity & Access Management (Users & Groups)
# ——————————————————————————————————————————————————————————————————————————————
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

    # 1. Shell users
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

        # Propagate existing cloud root SSH keys if available
        if [[ -f /root/.ssh/authorized_keys ]]; then
            mkdir -p "/home/$user/.ssh"
            cp /root/.ssh/authorized_keys "/home/$user/.ssh/authorized_keys"
            chown -R "$user:$user" "/home/$user/.ssh"
            chmod 700 "/home/$user/.ssh"
            chmod 600 "/home/$user/.ssh/authorized_keys"
        fi
    done

    # 2. SFTP-only isolated user bound to non-interactive shell
    if id "sftp_user" >/dev/null 2>&1; then
        log_info "User 'sftp_user' already exists. Skipping creation."
    else
        adduser --gecos "" --shell /usr/sbin/nologin --disabled-password sftp_user
        log_info "Created SFTP-only user 'sftp_user' with non-interactive shell."
        echo "--- Set password for sftp_user ---"
        passwd sftp_user
    fi

    # Set root user password
    echo "--- Set password for root user ---"
    passwd root

    # Assign supplementary groups
    usermod -aG vpn-users,ssh-users,sudo ssh_user
    usermod -aG vpn-users,ssh-users,sudo vpn_user
    usermod -aG sftp-users sftp_user
    log_info "User groups and administrative assignments updated."
}

# ——————————————————————————————————————————————————————————————————————————————
# Step 4: SFTP Chroot Jail Directory Hierarchy
# ——————————————————————————————————————————————————————————————————————————————
configure_sftp_chroot() {
    log_info "Applying SFTP directory ownership and isolation permissions..."

    # OpenSSH requirement: All directories in chroot path must be root-owned (mode 755)
    chown root:root /home/sftp_user
    chmod 755 /home/sftp_user

    # Dedicated writable staging area for SFTP transfers
    mkdir -p /home/sftp_user/upload
    chown sftp_user:sftp-users /home/sftp_user/upload
    chmod 775 /home/sftp_user/upload
    log_info "SFTP Chroot directory layout verified (/home/sftp_user/upload)."
}

# ——————————————————————————————————————————————————————————————————————————————
# Step 5: Sudoers Configuration
# ——————————————————————————————————————————————————————————————————————————————
configure_sudoers() {
    log_info "Configuring passwordless sudo access for group '%sudo'..."

    mkdir -p /etc/sudoers.d
    cp /etc/sudoers "/etc/sudoers.bak.$(date +%F-%T)"

    # Write drop-in rule for group %sudo
    cat > "$SUDOERS_FILE" <<'EOF'
%sudo ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 440 "$SUDOERS_FILE"

    # Validate syntax prior to commitment to avoid lockouts
    if ! visudo -c; then
        log_error "Syntax validation failed for $SUDOERS_FILE. Removing file to prevent lockout."
        rm -f "$SUDOERS_FILE"
        exit 1
    fi
    log_info "Sudoers syntax validated successfully."
}

# ——————————————————————————————————————————————————————————————————————————————
# Step 6: SSH Daemon Hardening & Ubuntu Socket Compatibility
# ——————————————————————————————————————————————————————————————————————————————
configure_ssh() {
    log_info "Configuring OpenSSH daemon settings..."

    cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.$(date +%F-%T)"

    # Helper function to set or replace sshd options
    set_sshd_param() {
        local param="$1"
        local value="$2"
        if grep -qE "^#?${param}" "$SSH_CONFIG"; then
            sed -i -E "s/^#?${param}.*/${param} ${value}/" "$SSH_CONFIG"
        else
            echo "${param} ${value}" >> "$SSH_CONFIG"
        fi
    }

    set_sshd_param "Port" "$SSH_PORT"
    set_sshd_param "PermitRootLogin" "yes"
    set_sshd_param "PasswordAuthentication" "yes"

    # Append SFTP Chroot match block if absent
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

    # Test configuration syntax before reloading
    if ! sshd -t; then
        log_error "SSHD configuration validation failed. Reverting from backup."
        cp "${SSH_CONFIG}.bak.$(date +%F-%T)" "$SSH_CONFIG"
        exit 1
    fi

    # Handle Ubuntu 22.10+ / 24.04 systemd socket activation
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        log_warn "Ubuntu systemd socket activation detected (ssh.socket). Migrating to standard service unit..."
        systemctl stop ssh.socket
        systemctl disable ssh.socket
    fi

    # Restart the SSH service unit
    if systemctl list-unit-files | grep -q "^ssh\.service"; then
        systemctl enable ssh.service
        systemctl restart ssh.service
    else
        systemctl enable sshd.service
        systemctl restart sshd.service
    fi

    log_info "SSH service successfully hardened and restarted on port $SSH_PORT."
}

# ——————————————————————————————————————————————————————————————————————————————
# Step 7: Firewall Management (UFW)
# ——————————————————————————————————————————————————————————————————————————————
configure_firewall() {
    log_info "Configuring Uncomplicated Firewall (UFW)..."

    # Baseline zero-trust traffic policy
    ufw default deny incoming
    ufw default allow outgoing

    # Essential baseline services
    ufw allow 80 comment 'HTTP'
    ufw allow 443 comment 'HTTPS'
    ufw allow 53 comment 'DNS'
    ufw allow "$SSH_PORT" comment 'Custom SSH'

    # Open pool of 10 ports for custom user services (without protocol restrictions)
    for port in {30001..30010}; do
        ufw allow "$port" comment 'Custom service'
    done

    # Commit firewall changes
    ufw --force enable
    log_info "UFW active and rules committed."
}

# ——————————————————————————————————————————————————————————————————————————————
# Step 8: Intrusion Prevention (Fail2Ban via systemd-journald)
# ——————————————————————————————————————————————————————————————————————————————
configure_fail2ban() {
    log_info "Configuring Fail2Ban intrusion prevention..."

    cat > "$FAIL2BAN_CONFIG" <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ${SSH_PORT}
backend = systemd
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    log_info "Fail2Ban service active and monitoring SSH on port ${SSH_PORT}."
}

# ——————————————————————————————————————————————————————————————————————————————
# Step 9: Optional Container Runtime (Docker & Docker Compose)
# ——————————————————————————————————————————————————————————————————————————————
install_docker() {
    local install_docker_prompt=""
    read -r -p "Install Docker CE and Docker Compose Plugin? (y/n): " install_docker_prompt
    if [[ "$install_docker_prompt" =~ ^[Yy]$ ]]; then
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

        usermod -aG docker ssh_user || true
        systemctl enable docker
        systemctl start docker
        log_info "Docker CE & Compose Plugin installed and service enabled."
    else
        log_info "Skipping Docker installation."
    fi
}

# ——————————————————————————————————————————————————————————————————————————————
# Main Entry Point
# ——————————————————————————————————————————————————————————————————————————————
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