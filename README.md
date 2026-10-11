<div align="center">

# ⚡ VPS Bootstrap (`vps-bootstrap`)

**Automated Day-0 Linux Baseline Provisioning, Security Hardening & Zero-Dependency Host Initialization**

[![Platform](https://img.shields.io/badge/Platform-Debian%2011%2F12%20%7C%20Ubuntu%2020.04--24.04%20LTS-E95420?style=for-the-badge&logo=linux&logoColor=white)](#-supported-platforms)
[![Security Hardening](https://img.shields.io/badge/Security-UFW%20%2B%20Fail2Ban%20%2B%20Chroot-00b894?style=for-the-badge&logo=shield&logoColor=white)](#-security-architecture--hardening-steps)
[![IaC Paradigm](https://img.shields.io/badge/IaC-Zero--Dependency%20Bash-0984e3?style=for-the-badge&logo=gnu-bash&logoColor=white)](#-architectural-highlights)
[![License: MIT](https://img.shields.io/badge/License-MIT-f1c40f?style=for-the-badge)](LICENSE)

<p align="center">
  <a href="#-quick-start">Quick Start</a> •
  <a href="#-user-roles--privilege-model">User Roles</a> •
  <a href="#-recommended-client-tooling">Client Tooling</a> •
  <a href="#-project-origin--evolution">Project Evolution</a> •
  <a href="#-firewall--network-matrix">Firewall Matrix</a> •
  <a href="#-post-provisioning-audit">Verification</a>
</p>

---

</div>

An idempotent, production-ready Bash automation suite engineered to initialize, harden, and bootstrap fresh **Debian** and **Ubuntu** cloud compute instances in under **90 seconds**.

It enforces a defensive security perimeter, eliminates manual configuration drift, provisions decoupled Role-Based Access Control (RBAC), isolates file transfers via SFTP chroot, and handles modern OS distribution quirks—without requiring external control nodes, Python virtual environments, or heavy orchestration agents.

---

## 👥 User Roles & Privilege Model

Rather than sharing a flat `root` account, the bootstrap engine establishes discrete identities based on the **Principle of Least Privilege (PoLP)**:

| Account | Shell / Access Level | Group Mapping | Purpose & Design Scope |
| :--- | :--- | :--- | :--- |
| **`ssh_user`** | `/bin/bash` (Interactive) | `ssh-users`, `vpn-users`, `sudo` | **Primary Host Administrator.** Designated account for daily operations, service deployment, container management, and administrative elevation via passwordless `sudo`. |
| **`vpn_user`** | `/bin/bash` (Interactive) | `vpn-users`, `ssh-users`, `sudo` | **Service & Automation Operator.** A secondary decoupled shell identity used for dedicated VPN network management, tunneling daemons, or backup maintenance tasks. |
| **`sftp_user`** | `/usr/sbin/nologin` (Jailed) | `sftp-users` | **Restricted File Transfer Account.** Strictly bound to an OpenSSH chroot jail. Blocked from TTY shell allocations, interactive logins, port forwarding, and directory traversal beyond `/upload`. |
| **`root`** | `/bin/bash` (System) | `root` | **Host Superuser.** Password is synchronized/rotated during bootstrap; direct remote administrative work should be transitioned to `ssh_user`. |

---

## 🔐 Recommended Client Tooling

To ensure a seamless, secure administrative workflow after running the setup, the following client toolset is recommended:

* **Credential Management:**  
  * Use **[KeePassXC](https://keepassxc.org/)** (local encrypted vault) or **[Bitwarden](https://bitwarden.com/)** (cloud-synchronized vault) to generate and store 20+ character passwords for `ssh_user`, `vpn_user`, `sftp_user`, and `root`. Avoid saving plain-text credentials in terminal notes or unencrypted files.
* **Terminal & Session Management:**  
  * On Windows/macOS, use **[MobaXterm](https://mobaxterm.mobatek.net/)**. It provides an integrated terminal client, an automatic graphical SFTP browser panel, multi-session tabs, and effortless handling of non-standard SSH ports (`30222`).

---

## 🔄 Project Origin & Evolution

This repository contains two iterations of the VPS provisioning workflow, demonstrating the engineering progression from a quick operational utility to an enterprise-grade automation baseline:

* **`vps-setup.sh` (Original Baseline):**  
  The initial operational script created for rapid VPS initialization prior to deploying self-hosted VPN servers and client tools. Focused purely on execution speed and basic host prep.
* **`vps-bootstrap.sh` (Advanced Portfolio & Production Release):**  
  A hardened, defensive evolution built to showcase production engineering standards. Adds defensive Bash error trapping (`set -euo pipefail`), mitigations for Ubuntu 24.04 socket activation conflicts, direct `systemd-journald` ingestion for Debian 12, automated OpenSSH chroot directory isolation, atomic sudoers validation (`visudo -c`), and a dedicated 10-port open application pool.

### Side-by-Side Comparison

| Architectural Feature | `vps-setup.sh` (Original) | `vps-bootstrap.sh` (Production) |
| :--- | :---: | :---: |
| **Primary Intent** | Rapid host prep for VPN nodes | Multi-service readiness & host hardening |
| **Shell Directives** | Standard execution flow | Strict `set -euo pipefail` |
| **Ubuntu 24.04 `ssh.socket` Fix** | ❌ Manual intervention | Automated migration to standard unit |
| **Fail2Ban Ingestion Engine** | File-based `/var/log/auth.log` | Direct `backend = systemd` |
| **Privilege Escalation Safety** | Standard file creation | Drop-in + `visudo -c` syntax check |
| **Application Ingress** | Fixed target ports | Open multi-protocol pool (`30001–30010`) |
| **Target Environment** | Personal ad-hoc VPS setups | Production cloud baseline & showcase |

---

## 💻 Supported Platforms

<table>
  <thead>
    <tr>
      <th>Distribution</th>
      <th>Supported Releases</th>
      <th>Kernel Compatibility</th>
      <th>Verification Status</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><strong>Ubuntu</strong></td>
      <td><code>20.04 LTS</code>, <code>22.04 LTS</code>, <code>24.04 LTS</code></td>
      <td>Linux 5.4 — 6.8+</td>
      <td><code>Passed (Verified)</code></td>
    </tr>
    <tr>
      <td><strong>Debian</strong></td>
      <td><code>11 (Bullseye)</code>, <code>12 (Bookworm)</code></td>
      <td>Linux 5.10 — 6.1+</td>
      <td><code>Passed (Verified)</code></td>
    </tr>
  </tbody>
</table>

---

## 🛡 Security Architecture & Hardening Steps

```text
 1. Pre-flight Checks    ▶  Validates EUID 0 (root), parses /etc/os-release, syncs UTC clock via NTP.
 2. System Tooling       ▶  Installs core triage tools, ensures sudo fallback on minimal Debian.
 3. Identity (RBAC)      ▶  Provisions decoupled security groups (ssh-users, vpn-users, sftp-users).
 4. SFTP Isolation       ▶  Applies strict root:root 755 chroot permissions with dedicated /upload dir.
 5. Sudoers Protection   ▶  Creates /etc/sudoers.d/90-nopasswd and runs atomic visudo -c check.
 6. SSH Daemon           ▶  Moves SSH to port 30222, resolves Ubuntu 24.04 ssh.socket conflict.
 7. Network Perimeter    ▶  Enforces UFW default-deny; exposes HTTP, HTTPS, DNS, SSH, and port pool.
 8. Intrusion Prevention ▶  Deploys Fail2Ban with native systemd-journald backend (1h ban / 5 retries).
 9. Container Engine     ▶  Optionally provisions official upstream Docker CE & Compose Plugin.

```

---

## 🌐 Firewall & Network Matrix

```text
PORT          PROTOCOL     STATE        SERVICE / INTENT
--------------------------------------------------------------------------------
53            ANY          ALLOW        DNS Resolution Service
80            ANY          ALLOW        HTTP Ingress (ACME Challenges / Web)
443           ANY          ALLOW        HTTPS Ingress (TLS Termination)
30222         ANY          ALLOW        Hardened OpenSSH Daemon
30001-30010   ANY          ALLOW        Open Custom Services Pool (Any Traffic)
[ALL OTHER]   ANY          DENY         Default Incoming Drop Policy

```

> [!NOTE]
> Ports **30001 through 30010** are pre-configured to accept all protocols without restrictions. You can bind containers and services directly to this range without needing to touch firewall rules.

* **Tunnels, Proxies & VPN Gateways:** WireGuard, OpenVPN, Shadowsocks, Xray / VLESS, sing-box.
* **Web Management Panels:** Portainer, Nginx Proxy Manager, Traefik Dashboard, Cockpit.
* **Monitoring & Observability:** Uptime Kuma, Netdata, Prometheus Node Exporter, Grafana.
* **Storage & File Sharing:** Filebrowser, Nextcloud, Syncthing, MinIO.
* **Network Diagnostics:** iPerf3 bandwidth testing, Speedtest Tracker.
* **Database & Cache GUIs:** pgAdmin, phpMyAdmin, RedisInsight.

---

## 🚀 Quick Start

### Option A: Advanced Hardened Provisioning (Recommended)

```bash
# 1. Download and mark executable
curl -fsSL -o vps-bootstrap.sh [https://raw.githubusercontent.com/](https://raw.githubusercontent.com/)<YOUR_USER>/vps-bootstrap/main/vps-bootstrap.sh
chmod +x vps-bootstrap.sh

# 2. Run with root privileges
sudo ./vps-bootstrap.sh

```

### Option B: Original Lightweight Baseline

```bash
curl -fsSL -o vps-setup.sh [https://raw.githubusercontent.com/](https://raw.githubusercontent.com/)<YOUR_USER>/vps-bootstrap/main/vps-setup.sh
chmod +x vps-setup.sh
sudo ./vps-setup.sh

```

> [!TIP]
> During script execution, you will be prompted to set passwords for `ssh_user`, `vpn_user`, `sftp_user`, and `root`. Generate strong unique passwords in **Bitwarden** or **KeePassXC** beforehand to easily paste them during setup.

---

## 🔍 Post-Provisioning Audit

### Connecting with MobaXterm

1. Click **Session** ➔ **SSH**.
2. **Remote host:** `<HOST_IP>`
3. **Specify username:** check the box and enter `ssh_user` (or `sftp_user` for file browsing).
4. **Port:** change default `22` to **`30222`**.
5. Click **OK** and authenticate using the credentials stored in your password manager.

### Manual Verification via Terminal

```bash
# 1. Connect via SSH on the custom management port
ssh -p 30222 ssh_user@<HOST_IP>

# 2. Verify SFTP chroot boundary (interactive shell must terminate with code 1)
sftp -P 30222 sftp_user@<HOST_IP>
ssh -p 30222 sftp_user@<HOST_IP>

# 3. Check firewall rules
sudo ufw status verbose

# 4. Check Fail2Ban active jail
sudo fail2ban-client status sshd

# 5. Review bootstrap audit records
cat /var/log/vps_bootstrap.log

```

---

## 📁 Repository Structure

```text
vps-bootstrap/
├── .gitignore
├── LICENSE               # MIT License
├── README.md             # Comprehensive architecture & operational documentation
├── vps-setup.sh          # Original lightweight script (rapid VPN host initialization)
└── vps-bootstrap.sh      # Advanced production script (defensive hardening baseline)

```

---

## 📄 License

This project is licensed under the [MIT License](https://www.google.com/search?q=LICENSE) — free for use in personal, open-source, and commercial infrastructure.

