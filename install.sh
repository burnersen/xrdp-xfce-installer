#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# XRDP + XFCE Remote Desktop Installer
#
# Ubuntu 20.04+
#
# Features:
#   - XFCE desktop reachable over RDP
#   - Persistent sessions (reconnect from any device/IP)
#   - Custom RDP port
#   - UFW firewall (SSH access is preserved)
#   - fail2ban for SSH and XRDP
#   - Fast DNS resolvers (the provider name servers are replaced)
#   - Google Chrome and Firefox (Firefox from Mozilla APT, not Snap)
#   - Optional: JDownloader 2 (desktop app or headless service)
# ==========================================================

on_error() {
    local exit_code=$?

    echo >&2
    echo "==================================================" >&2
    echo " ERROR: Installation failed" >&2
    echo " Line:    $1" >&2
    echo " Command: $2" >&2
    echo " Exit:    $exit_code" >&2
    echo "==================================================" >&2

    exit "$exit_code"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR


# ----------------------------------------------------------
# ROOT CHECK
# ----------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run as root." >&2
    echo "Example: sudo -i" >&2
    exit 1
fi


# ----------------------------------------------------------
# INTERACTIVE TERMINAL CHECK
# ----------------------------------------------------------

if ! true </dev/tty 2>/dev/null; then
    echo "ERROR: An interactive TTY is required." >&2
    exit 1
fi


echo "=================================================="
echo " XRDP + XFCE Remote Desktop Installer"
echo " Ubuntu 20.04+"
echo "=================================================="
echo


# ----------------------------------------------------------
# OS CHECK
# ----------------------------------------------------------

if [[ ! -r /etc/os-release ]]; then
    echo "ERROR: /etc/os-release not found." >&2
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "ERROR: This installer supports Ubuntu only." >&2
    exit 1
fi

UBUNTU_VERSION="${VERSION_ID:-}"

if [[ -z "$UBUNTU_VERSION" ]]; then
    echo "ERROR: Unable to determine Ubuntu version." >&2
    exit 1
fi

if ! dpkg --compare-versions "$UBUNTU_VERSION" ge "20.04"; then
    echo "ERROR: Ubuntu 20.04 or newer is required." >&2
    exit 1
fi

ARCH="$(dpkg --print-architecture)"

echo "Detected system:"
echo "  OS:   ${PRETTY_NAME:-Ubuntu}"
echo "  Arch: $ARCH"
echo


# ----------------------------------------------------------
# HELPERS
# ----------------------------------------------------------

is_valid_ipv4() {
    local ip="$1"
    local octet
    local -a octets

    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1

    IFS='.' read -r -a octets <<< "$ip"

    [[ "${#octets[@]}" -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do

        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1

        if (( 10#$octet > 255 )); then
            return 1
        fi

    done

    return 0
}


# Set a key in an INI style file.
#
# Replaces the FIRST active key, uncomments the first
# commented key, or appends the key if it is missing.
#
# Only the first occurrence is touched on purpose.
# xrdp.ini contains several "port=" lines: the listening
# port in [Globals], plus per-module values such as
# "port=-1" and "port=ask3389". Replacing all of them
# breaks the session backend.

set_ini_key() {

    local file="$1"
    local key="$2"
    local value="$3"

    if [[ ! -f "$file" ]]; then
        echo "WARNING: $file not found, skipping $key."
        return 0
    fi

    if grep -qE "^[[:space:]]*${key}=" "$file"; then

        sed -i -E "0,/^[[:space:]]*${key}=.*/s||${key}=${value}|" "$file"

    elif grep -qE "^[[:space:]]*[;#][[:space:]]*${key}=" "$file"; then

        sed -i -E "0,/^[[:space:]]*[;#][[:space:]]*${key}=.*/s||${key}=${value}|" "$file"

    else

        printf '%s=%s\n' "$key" "$value" >> "$file"

    fi
}


# ----------------------------------------------------------
# USERNAME
# ----------------------------------------------------------

read -rp \
    "Enter username to create for RDP [user]: " \
    USERNAME < /dev/tty

USERNAME="${USERNAME:-user}"

if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] ||
   (( ${#USERNAME} > 32 )); then

    echo "ERROR: Invalid username." >&2
    echo "Use lowercase letters, numbers, '_' or '-'." >&2
    echo "Username must start with a letter or '_'." >&2
    exit 1
fi

if [[ "$USERNAME" == "root" ]]; then
    echo "ERROR: root cannot be used as the RDP user." >&2
    exit 1
fi

USER_EXISTS=false

if id "$USERNAME" &>/dev/null; then

    EXISTING_UID="$(id -u "$USERNAME")"

    if (( EXISTING_UID < 1000 )); then
        echo "ERROR: '$USERNAME' is a system account (UID $EXISTING_UID)." >&2
        exit 1
    fi

    echo
    echo "WARNING: User '$USERNAME' already exists."
    echo
    echo "Continuing will:"
    echo "  - reset its password"
    echo "  - add it to the sudo group"
    echo "  - configure its XFCE XRDP session"
    echo

    read -rp \
        "Continue with the existing user? [y/N]: " \
        USE_EXISTING < /dev/tty

    USE_EXISTING="${USE_EXISTING:-N}"

    if ! [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi

    USER_EXISTS=true
fi


# ----------------------------------------------------------
# RDP PORT
#
# The default port 3389 is scanned constantly by bots.
# A non standard port removes most of that noise.
# ----------------------------------------------------------

echo

read -rp \
    "RDP port [3389]: " \
    RDP_PORT < /dev/tty

RDP_PORT="${RDP_PORT:-3389}"

if ! [[ "$RDP_PORT" =~ ^[0-9]+$ ]] ||
   (( RDP_PORT < 1 || RDP_PORT > 65535 )); then

    echo "ERROR: Invalid port number." >&2
    exit 1
fi

if (( RDP_PORT < 1024 )) && (( RDP_PORT != 3389 )); then
    echo "ERROR: Ports below 1024 are reserved for system services." >&2
    exit 1
fi

# Ports that would collide with other common services.

for RESERVED in 22 80 443 3350 5900 9666; do

    if (( RDP_PORT == RESERVED )); then
        echo "ERROR: Port $RDP_PORT is used by another service." >&2
        exit 1
    fi

done

if (( RDP_PORT == 3389 )); then
    echo "NOTE: Using the default RDP port. Expect automated scans."
else
    echo "NOTE: Clients must connect using <SERVER_IP>:$RDP_PORT"
fi


# ----------------------------------------------------------
# RDP ACCESS
# ----------------------------------------------------------

echo

read -rp \
    "Restrict RDP access to one IPv4 address? [Y/n]: " \
    LIMIT_RDP < /dev/tty

LIMIT_RDP="${LIMIT_RDP:-Y}"

if [[ "$LIMIT_RDP" =~ ^[Yy]$ ]]; then

    while true; do

        read -rp \
            "Enter allowed public IPv4 address: " \
            ALLOWED_IP < /dev/tty

        if is_valid_ipv4 "$ALLOWED_IP"; then
            break
        fi

        echo "ERROR: Invalid IPv4 address."
        echo "Example: 203.0.113.10"

    done

    MIN_PASSWORD_LENGTH=8

elif [[ "$LIMIT_RDP" =~ ^[Nn]$ ]]; then

    echo
    echo "WARNING:"
    echo "TCP port $RDP_PORT will be accessible from the Internet."
    echo "Use a long, randomly generated password."
    echo

    read -rp \
        "Type OPEN to confirm: " \
        OPEN_CONFIRM < /dev/tty

    if [[ "$OPEN_CONFIRM" != "OPEN" ]]; then
        echo "Installation cancelled."
        exit 0
    fi

    ALLOWED_IP=""
    MIN_PASSWORD_LENGTH=12

else

    echo "ERROR: Please answer y or n." >&2
    exit 1

fi


# ----------------------------------------------------------
# OPTIONAL COMPONENTS
# ----------------------------------------------------------

echo

read -rp \
    "Install JDownloader 2? [y/N]: " \
    INSTALL_JD < /dev/tty

INSTALL_JD="${INSTALL_JD:-N}"

JD_MODE="none"

if [[ "$INSTALL_JD" =~ ^[Yy]$ ]]; then

    echo
    echo "How should JDownloader run?"
    echo
    echo "  1) Desktop application"
    echo "     Runs inside the XFCE session."
    echo "     Full GUI, works together with a browser on the same"
    echo "     machine (Click'n'Load)."
    echo "     Stops when the session is logged out."
    echo
    echo "  2) Headless service"
    echo "     Runs as a systemd service, starts at boot."
    echo "     No GUI, controlled through my.jdownloader.org."
    echo "     Survives reboots and disconnects."
    echo

    read -rp \
        "Select [1/2]: " \
        JD_CHOICE < /dev/tty

    case "$JD_CHOICE" in
        1) JD_MODE="desktop" ;;
        2) JD_MODE="service" ;;
        *)
            echo "ERROR: Please select 1 or 2." >&2
            exit 1
            ;;
    esac

fi


# ----------------------------------------------------------
# PASSWORD
# ----------------------------------------------------------

echo
echo "Enter password for Linux user '$USERNAME'."
echo "Minimum length: $MIN_PASSWORD_LENGTH characters."
echo

read -rsp \
    "Password: " \
    USER_PASSWORD < /dev/tty

echo

read -rsp \
    "Confirm password: " \
    USER_PASSWORD_CONFIRM < /dev/tty

echo

if [[ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]]; then
    echo "ERROR: Passwords do not match." >&2
    exit 1
fi

if (( ${#USER_PASSWORD} < MIN_PASSWORD_LENGTH )); then
    echo "ERROR: Password must contain at least $MIN_PASSWORD_LENGTH characters." >&2
    exit 1
fi


# ----------------------------------------------------------
# DNS RESOLVERS
#
# Some hosting providers ship name servers that throttle
# bursts of queries. A browser resolves 20-50 names while
# building a single page, so the throttling shows up as pages
# that load slowly or time out - while a single lookup on the
# command line still looks perfectly healthy.
#
# The addresses are replaced where netplan configures the
# link. Name servers defined there take precedence over
# anything in resolved.conf, and netplan MERGES lists from
# additional files instead of replacing them - so editing the
# existing file is the only reliable way.
# ----------------------------------------------------------

echo
echo "[1/13] Configuring DNS resolvers"

readonly DNS_PRIMARY="1.1.1.1"
readonly DNS_SECONDARY="8.8.8.8"

export DEBIAN_FRONTEND=noninteractive

# "sed -n 1p" instead of "head -n1": a reader that closes the
# pipe early kills grep with SIGPIPE, which "set -o pipefail"
# would report as a failure.
NETPLAN_FILE="$(grep -l 'nameservers' /etc/netplan/*.yaml 2>/dev/null | sed -n '1p' || true)"

if [[ -z "$NETPLAN_FILE" ]]; then

    echo "No netplan file with name servers found - keeping current setup."

else

    echo "Setting $DNS_PRIMARY and $DNS_SECONDARY in $NETPLAN_FILE"

    NETPLAN_BACKUP="${NETPLAN_FILE}.backup_$(date +%Y%m%d_%H%M%S)"
    cp -a "$NETPLAN_FILE" "$NETPLAN_BACKUP"

    if ! python3 -c 'import yaml' 2>/dev/null; then
        apt-get update
        apt-get install -y python3-yaml
    fi

    # Rewriting the YAML is safer than a text substitution:
    # the provider addresses differ between machines.
    python3 - "$NETPLAN_FILE" "$DNS_PRIMARY" "$DNS_SECONDARY" <<'PYTHON'
import sys
import yaml

path, primary, secondary = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path) as handle:
    config = yaml.safe_load(handle) or {}

devices = config.get("network", {}).get("ethernets", {})

if not devices:
    sys.exit("no ethernet device found in netplan configuration")

for device in devices.values():
    device.setdefault("nameservers", {})["addresses"] = [primary, secondary]

with open(path, "w") as handle:
    yaml.safe_dump(config, handle, default_flow_style=False, sort_keys=False)
PYTHON

    chmod 600 "$NETPLAN_FILE"

    # "netplan generate" only validates the files and writes the
    # backend configuration. It does not touch the running network,
    # so a broken file is caught before it can cut the connection.
    if netplan generate; then

        netplan apply
        sleep 2

        echo "Name servers now in use:"
        resolvectl status 2>/dev/null \
            | grep -i 'DNS Server' \
            | sed 's/^/  /' || true

    else

        echo "WARNING: netplan rejected the change - restoring the backup."
        cp -a "$NETPLAN_BACKUP" "$NETPLAN_FILE"
        netplan generate || true

    fi

    # Without this, cloud-init writes the provider's name servers
    # back into the file on the next boot.
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
        echo 'network: {config: disabled}' \
            > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    fi

fi


# ----------------------------------------------------------
# SYSTEM UPDATE
# ----------------------------------------------------------

echo
echo "[2/13] Updating system"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y


# ----------------------------------------------------------
# INSTALL CORE PACKAGES
# ----------------------------------------------------------

echo
echo "[3/13] Installing XFCE, XRDP and dependencies"

apt-get install -y \
    sudo \
    xfce4 \
    xfce4-goodies \
    xrdp \
    xorgxrdp \
    xserver-xorg-core \
    dbus-x11 \
    x11-xserver-utils \
    ufw \
    fail2ban \
    tmux \
    wget \
    curl \
    ca-certificates \
    gnupg


# ----------------------------------------------------------
# POLKIT PACKAGE
#
# Package name differs between Ubuntu releases.
# ----------------------------------------------------------

POLKIT_PKG=""

if apt-cache show polkitd >/dev/null 2>&1; then

    POLKIT_PKG="polkitd"

elif apt-cache show policykit-1 >/dev/null 2>&1; then

    POLKIT_PKG="policykit-1"

fi

if [[ -n "$POLKIT_PKG" ]]; then

    echo "Installing polkit package: $POLKIT_PKG"
    apt-get install -y "$POLKIT_PKG"

else

    echo "WARNING: No supported polkit package was found."
    echo "XRDP installation will continue."

fi


# ----------------------------------------------------------
# FUSE 2 (APPIMAGE SUPPORT)
#
# AppImages require libfuse.so.2. Ubuntu 24.04 and newer no
# longer ship it by default, and renamed the package to
# libfuse2t64.
#
# Without it, AppImages fail to start with a message about a
# missing FUSE library.
# ----------------------------------------------------------

FUSE_PKG=""

if apt-cache show libfuse2t64 >/dev/null 2>&1; then

    FUSE_PKG="libfuse2t64"

elif apt-cache show libfuse2 >/dev/null 2>&1; then

    FUSE_PKG="libfuse2"

fi

if [[ -n "$FUSE_PKG" ]]; then

    echo "Installing FUSE 2 package for AppImage support: $FUSE_PKG"

    if ! apt-get install -y "$FUSE_PKG" fuse3; then
        echo "WARNING: FUSE installation failed. AppImages may not start."
    fi

else

    echo "WARNING: No FUSE 2 package found. AppImages may not start."

fi


# ----------------------------------------------------------
# XRDP CONFIGURATION
# ----------------------------------------------------------

echo
echo "[4/13] Configuring XRDP"

if getent group ssl-cert >/dev/null 2>&1; then
    usermod -aG ssl-cert xrdp
fi

XRDP_INI="/etc/xrdp/xrdp.ini"
SESMAN_INI="/etc/xrdp/sesman.ini"

if [[ -f "$XRDP_INI" && ! -f "${XRDP_INI}.orig" ]]; then
    cp "$XRDP_INI" "${XRDP_INI}.orig"
fi

if [[ -f "$SESMAN_INI" && ! -f "${SESMAN_INI}.orig" ]]; then
    cp "$SESMAN_INI" "${SESMAN_INI}.orig"
fi

# Listening port.

set_ini_key "$XRDP_INI" "port" "$RDP_PORT"

# Fixed colour depth.
#
# XRDP creates a SEPARATE session per colour depth. Different
# clients negotiate different values, which silently produces
# several parallel sessions for the same user.
#
# Capping the value keeps all clients in one single session.

set_ini_key "$XRDP_INI" "max_bpp" "24"


# ----------------------------------------------------------
# PERSISTENT SESSIONS
#
# The goal: reconnecting from any client, any IP and any
# window size lands in the SAME session, with all running
# applications still open.
#
#   Policy=Default            session per <User,BitPerPixel>
#   KillDisconnected=false    keep the session after disconnect
#   DisconnectedTimeLimit=0   never expire a disconnected session
#
# Note: combined with max_bpp above, "Default" means exactly
# one session per user.
# ----------------------------------------------------------

echo
echo "[5/13] Configuring persistent sessions"

set_ini_key "$SESMAN_INI" "Policy" "Default"
set_ini_key "$SESMAN_INI" "KillDisconnected" "false"
set_ini_key "$SESMAN_INI" "DisconnectedTimeLimit" "0"
set_ini_key "$SESMAN_INI" "IdleTimeLimit" "0"

# A low limit surfaces stale sessions early instead of
# letting dozens of them pile up unnoticed.

set_ini_key "$SESMAN_INI" "MaxSessions" "3"

systemctl enable xrdp

systemctl restart xrdp-sesman
systemctl restart xrdp


# ----------------------------------------------------------
# CREATE / CONFIGURE USER
# ----------------------------------------------------------

echo
echo "[6/13] Configuring user '$USERNAME'"

if [[ "$USER_EXISTS" == false ]]; then

    adduser \
        --disabled-password \
        --gecos "" \
        "$USERNAME"

fi

# Send the password through stdin.
# Do not use command-line arguments or Bash here-strings.

printf '%s:%s\n' \
    "$USERNAME" \
    "$USER_PASSWORD" |
    chpasswd

unset USER_PASSWORD
unset USER_PASSWORD_CONFIRM

usermod -aG sudo "$USERNAME"


# ----------------------------------------------------------
# DETECT USER HOME
# ----------------------------------------------------------

PASSWD_ENTRY="$(getent passwd "$USERNAME")"

if [[ -z "$PASSWD_ENTRY" ]]; then
    echo "ERROR: Unable to read passwd entry for '$USERNAME'." >&2
    exit 1
fi

IFS=':' read -r _ _ _ _ _ HOME_DIR _ <<< "$PASSWD_ENTRY"

if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
    echo "ERROR: Invalid home directory for '$USERNAME': $HOME_DIR" >&2
    exit 1
fi

USER_GROUP="$(id -gn "$USERNAME")"


# ----------------------------------------------------------
# XFCE SESSION
# ----------------------------------------------------------

echo
echo "[7/13] Configuring XFCE session"

cat > "$HOME_DIR/.xsession" <<'EOF'
exec startxfce4
EOF

chown "$USERNAME:$USER_GROUP" "$HOME_DIR/.xsession"
chmod 0644 "$HOME_DIR/.xsession"


# ----------------------------------------------------------
# POLKIT / XRDP
#
# Prevent common colord authentication dialogs in XRDP.
#
# Legacy polkit uses .pkla.
# Modern polkit uses JavaScript rules.
# ----------------------------------------------------------

echo
echo "[8/13] Configuring polkit for XRDP"

if command -v pkaction >/dev/null 2>&1; then

    POLKIT_OUTPUT="$(pkaction --version 2>/dev/null || true)"
    POLKIT_VERSION="${POLKIT_OUTPUT##* }"
    POLKIT_MAJOR="${POLKIT_VERSION%%.*}"

    echo "Detected polkit version: ${POLKIT_VERSION:-unknown}"

    if [[ "$POLKIT_MAJOR" =~ ^[0-9]+$ ]] &&
       (( POLKIT_MAJOR >= 121 )); then

        echo "Using modern polkit JavaScript rules."

        mkdir -p /etc/polkit-1/rules.d

        cat > /etc/polkit-1/rules.d/45-xrdp-colord.rules <<EOF
/*
 * Allow ordinary colord operations for the XRDP user.
 *
 * install-system-wide is deliberately NOT allowed.
 */

polkit.addRule(function(action, subject) {

    var allowedActions = [
        "org.freedesktop.color-manager.create-device",
        "org.freedesktop.color-manager.create-profile",
        "org.freedesktop.color-manager.delete-device",
        "org.freedesktop.color-manager.delete-profile",
        "org.freedesktop.color-manager.modify-device",
        "org.freedesktop.color-manager.modify-profile"
    ];

    if (subject.user === "$USERNAME" &&
        allowedActions.indexOf(action.id) !== -1) {

        return polkit.Result.YES;
    }
});
EOF

        chown root:root \
            /etc/polkit-1/rules.d/45-xrdp-colord.rules

        chmod 0644 \
            /etc/polkit-1/rules.d/45-xrdp-colord.rules

        rm -f \
            /etc/polkit-1/localauthority/50-local.d/45-xrdp-colord.pkla

    else

        echo "Using legacy polkit .pkla rules."

        mkdir -p \
            /etc/polkit-1/localauthority/50-local.d

        cat > \
            /etc/polkit-1/localauthority/50-local.d/45-xrdp-colord.pkla <<EOF
[Allow colord operations for XRDP user]
Identity=unix-user:$USERNAME
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=yes
EOF

        chown root:root \
            /etc/polkit-1/localauthority/50-local.d/45-xrdp-colord.pkla

        chmod 0644 \
            /etc/polkit-1/localauthority/50-local.d/45-xrdp-colord.pkla

        rm -f \
            /etc/polkit-1/rules.d/45-xrdp-colord.rules

    fi

    systemctl restart polkit.service 2>/dev/null || true

else

    echo "WARNING: pkaction was not found."
    echo "Skipping XRDP polkit configuration."

fi


# ----------------------------------------------------------
# FIREWALL
# ----------------------------------------------------------

echo
echo "[9/13] Configuring UFW"

declare -a SSH_PORTS=()


add_ssh_port() {

    local port="$1"
    local existing

    [[ "$port" =~ ^[0-9]+$ ]] || return 0

    if (( port < 1 || port > 65535 )); then
        return 0
    fi

    for existing in "${SSH_PORTS[@]}"; do

        if [[ "$existing" == "$port" ]]; then
            return 0
        fi

    done

    SSH_PORTS+=("$port")
}


# ----------------------------------------------------------
# CURRENT SSH CONNECTION
#
# Preserve the SSH port used by this connection.
# ----------------------------------------------------------

if [[ -n "${SSH_CONNECTION:-}" ]]; then

    read -r _ _ _ SSH_CURRENT_PORT <<< "$SSH_CONNECTION"

    add_ssh_port "$SSH_CURRENT_PORT"

fi


# ----------------------------------------------------------
# EFFECTIVE SSHD CONFIGURATION
# ----------------------------------------------------------

if command -v sshd >/dev/null 2>&1; then

    SSHD_CONFIG="$(sshd -T 2>/dev/null || true)"

    while read -r KEY VALUE _; do

        if [[ "$KEY" == "port" ]]; then
            add_ssh_port "$VALUE"
        fi

    done <<< "$SSHD_CONFIG"

fi


# ----------------------------------------------------------
# SSH FALLBACK
# ----------------------------------------------------------

if (( ${#SSH_PORTS[@]} == 0 )); then
    add_ssh_port 22
fi

echo "Preserving SSH access on port(s): ${SSH_PORTS[*]}"

for SSH_PORT in "${SSH_PORTS[@]}"; do

    ufw allow \
        "${SSH_PORT}/tcp" \
        comment "SSH"

done


# ----------------------------------------------------------
# REMOVE OLD RDP FIREWALL RULES
#
# Removes existing rules for the default port and for the
# configured port, so an old "ALLOW Anywhere" rule cannot
# survive the installation.
# ----------------------------------------------------------

UFW_ADDED_RULES="$(
    LC_ALL=C ufw show added 2>/dev/null || true
)"

while IFS= read -r UFW_LINE; do

    [[ "$UFW_LINE" == ufw\ * ]] || continue

    RULE="${UFW_LINE#ufw }"

    # Remove optional comment.
    RULE="${RULE%% comment *}"

    IS_RDP_RULE=false

    for CHECK_PORT in 3389 "$RDP_PORT"; do

        # Examples:
        #
        # allow 3389
        # allow 3389/tcp

        if [[ "$RULE" =~ ^(allow|deny|reject|limit)[[:space:]]+${CHECK_PORT}(/tcp)?([[:space:]]|$) ]]; then
            IS_RDP_RULE=true
        fi

        # Example:
        #
        # allow from 203.0.113.10 to any port 3389 proto tcp

        if [[ "$RULE" =~ to[[:space:]]+any[[:space:]]+port[[:space:]]+${CHECK_PORT}([[:space:]]|$) ]]; then
            IS_RDP_RULE=true
        fi

    done

    if [[ "$IS_RDP_RULE" == true ]]; then

        echo "Removing existing RDP firewall rule:"
        echo "  ufw $RULE"

        read -r -a RULE_ARGS <<< "$RULE"

        if ! ufw delete "${RULE_ARGS[@]}"; then

            echo >&2
            echo "ERROR: Failed to remove an existing RDP firewall rule:" >&2
            echo "  ufw $RULE" >&2
            echo >&2
            echo "Firewall configuration aborted." >&2
            echo "An old public RDP rule may still be active." >&2

            exit 1
        fi

    fi

done <<< "$UFW_ADDED_RULES"


# ----------------------------------------------------------
# FIREWALL DEFAULTS
# ----------------------------------------------------------

ufw default deny incoming
ufw default allow outgoing


# ----------------------------------------------------------
# RDP FIREWALL RULE
# ----------------------------------------------------------

if [[ "$LIMIT_RDP" =~ ^[Yy]$ ]]; then

    ufw allow \
        from "$ALLOWED_IP" \
        to any \
        port "$RDP_PORT" \
        proto tcp \
        comment "XRDP"

    echo "RDP access restricted to: $ALLOWED_IP"

else

    ufw allow \
        "${RDP_PORT}/tcp" \
        comment "XRDP"

    echo "WARNING: RDP is accessible from any IP."

fi

ufw --force enable


# ----------------------------------------------------------
# FAIL2BAN
#
# Bans an IP after repeated failed logins. The port stays
# open for everyone else.
#
# Ubuntu ships a filter for SSH only, so the XRDP filter is
# created here.
# ----------------------------------------------------------

echo
echo "[10/13] Configuring fail2ban"

SESMAN_LOG="/var/log/xrdp-sesman.log"

cat > /etc/fail2ban/filter.d/xrdp.conf <<'EOF'
# Matches the AUTHFAIL line written by xrdp-sesman, e.g.
#
#   [20260101-12:00:00] [INFO ] AUTHFAIL: user=name ip=::ffff:203.0.113.10 time=...
#
# The optional ::ffff: prefix is how an IPv4 address is
# represented inside an IPv6 field.

[Definition]
failregex = AUTHFAIL: user=\S* ip=(?:::ffff:)?<HOST>
ignoreregex =
datepattern = ^\[%%Y%%m%%d-%%H:%%M:%%S\]
EOF

chmod 0644 /etc/fail2ban/filter.d/xrdp.conf

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true

[xrdp]
enabled  = true
port     = $RDP_PORT
filter   = xrdp
logpath  = $SESMAN_LOG
backend  = auto
maxretry = 5
bantime  = 1h
EOF

chmod 0644 /etc/fail2ban/jail.local

# fail2ban refuses to start a jail whose log file is missing.

if [[ ! -f "$SESMAN_LOG" ]]; then
    touch "$SESMAN_LOG"
    chmod 0640 "$SESMAN_LOG"
fi

systemctl enable fail2ban
systemctl restart fail2ban


# ----------------------------------------------------------
# BROWSERS
# ----------------------------------------------------------

echo
echo "[11/13] Installing browsers"


# ----------------------------------------------------------
# GOOGLE CHROME
#
# Google's official Linux .deb is amd64 only.
# ----------------------------------------------------------

if [[ "$ARCH" == "amd64" ]]; then

    echo "Installing Google Chrome..."

    CHROME_DEB="/tmp/google-chrome-stable_current_amd64.deb"

    if wget \
        -qO "$CHROME_DEB" \
        "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"; then

        if ! apt-get install -y "$CHROME_DEB"; then

            echo "WARNING: Initial Chrome installation failed."
            echo "Attempting dependency repair..."

            apt-get -f install -y || true

            if ! apt-get install -y "$CHROME_DEB"; then
                echo "WARNING: Google Chrome could not be installed."
            fi

        fi

    else

        echo "WARNING: Failed to download Google Chrome."

    fi

    rm -f "$CHROME_DEB"

else

    echo "Google Chrome is unavailable for architecture '$ARCH'."
    echo "Trying Chromium instead..."

    if apt-cache show chromium-browser >/dev/null 2>&1; then

        if ! apt-get install -y chromium-browser; then
            echo "WARNING: Chromium installation failed."
        fi

    elif apt-cache show chromium >/dev/null 2>&1; then

        if ! apt-get install -y chromium; then
            echo "WARNING: Chromium installation failed."
        fi

    else

        echo "WARNING: Chromium package was not found."

    fi

fi


# ----------------------------------------------------------
# FIREFOX
#
# Ubuntu's "firefox" package is only a wrapper that installs
# the Snap build. That build misbehaves inside an XRDP or
# Sunshine session, so the official Mozilla APT repository is
# used instead.
#
# The APT pin is not optional: without it Ubuntu's wrapper
# wins the next upgrade and drags the Snap back in.
#
# Browser installation failure is non-fatal.
# ----------------------------------------------------------

echo "Installing Firefox from Mozilla's APT repository..."

# Remove the Snap build and the wrapper package first.
if command -v snap >/dev/null 2>&1; then
    snap remove --purge firefox >/dev/null 2>&1 || true
fi

apt-get purge -y firefox >/dev/null 2>&1 || true

install -d -m 0755 /etc/apt/keyrings

if wget -qO- "https://packages.mozilla.org/apt/repo-signing-key.gpg" \
    > /etc/apt/keyrings/packages.mozilla.org.asc; then

    chmod 0644 /etc/apt/keyrings/packages.mozilla.org.asc

    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list

    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
        > /etc/apt/preferences.d/mozilla

    apt-get update

    if ! apt-get install -y firefox; then
        echo "WARNING: Firefox installation failed."
    fi

else

    echo "WARNING: Could not download Mozilla's signing key."
    echo "Firefox was skipped."

fi


# ----------------------------------------------------------
# JDOWNLOADER (OPTIONAL)
# ----------------------------------------------------------

echo
echo "[12/13] Installing optional components"

JD_DIR="/opt/jdownloader"

if [[ "$JD_MODE" != "none" ]]; then

    echo "Installing JDownloader 2 ($JD_MODE mode)..."

    # The desktop application needs the FULL JRE.
    #
    # openjdk-*-jre-headless has no windowing support, so
    # JDownloader would silently fall back to headless mode
    # even with a valid DISPLAY.

    if [[ "$JD_MODE" == "desktop" ]]; then
        JAVA_PKG="default-jre"
    else
        JAVA_PKG="default-jre-headless"
    fi

    if ! apt-get install -y "$JAVA_PKG"; then
        echo "WARNING: Could not install $JAVA_PKG."
        echo "Skipping JDownloader installation."
        JD_MODE="none"
    fi

fi

if [[ "$JD_MODE" != "none" ]]; then

    mkdir -p "$JD_DIR"

    if wget \
        -qO "$JD_DIR/JDownloader.jar" \
        "http://installer.jdownloader.org/JDownloader.jar"; then

        chown -R "$USERNAME:$USER_GROUP" "$JD_DIR"

        if [[ "$JD_MODE" == "service" ]]; then

            cat > /etc/systemd/system/jdownloader.service <<EOF
[Unit]
Description=JDownloader 2 headless
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USERNAME
Group=$USER_GROUP
WorkingDirectory=$JD_DIR
ExecStart=/usr/bin/java -Djava.awt.headless=true -jar $JD_DIR/JDownloader.jar
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

            systemctl daemon-reload

            # Deliberately NOT started here: the first run is
            # interactive and asks for My JDownloader credentials.

            systemctl enable jdownloader

            echo "JDownloader service created (not started yet)."

        else

            cat > /usr/share/applications/jdownloader.desktop <<EOF
[Desktop Entry]
Type=Application
Name=JDownloader 2
Comment=Download Manager
Exec=java -jar $JD_DIR/JDownloader.jar
Path=$JD_DIR
Terminal=false
Categories=Network;FileTransfer;
StartupNotify=true
EOF

            chmod 0644 /usr/share/applications/jdownloader.desktop
            update-desktop-database 2>/dev/null || true

            echo "JDownloader menu entry created."

        fi

    else

        echo "WARNING: Failed to download JDownloader."
        JD_MODE="none"

    fi

fi


# ----------------------------------------------------------
# SESSION RESET HELPER
#
# A stuck window manager can leave a session that refuses
# new connections. This helper clears it from SSH.
# ----------------------------------------------------------

cat > /usr/local/bin/xrdp-session-reset <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\$EUID" -ne 0 ]]; then
    echo "Please run as root." >&2
    exit 1
fi

echo "Terminating all processes of user '$USERNAME'..."

pkill -u "$USERNAME" || true
sleep 2

systemctl restart xrdp-sesman
systemctl restart xrdp

echo "Done. Reconnect using <SERVER_IP>:$RDP_PORT"
EOF

chmod 0755 /usr/local/bin/xrdp-session-reset


# ----------------------------------------------------------
# VERIFY
# ----------------------------------------------------------

echo
echo "[13/13] Verifying installation"

INSTALL_OK=true


if systemctl is-active --quiet xrdp; then
    echo "XRDP:         active"
else
    echo "XRDP:         FAILED"
    INSTALL_OK=false
fi


if systemctl is-active --quiet xrdp-sesman; then
    echo "XRDP sesman:  active"
else
    echo "XRDP sesman:  FAILED"
    INSTALL_OK=false
fi


if systemctl is-active --quiet fail2ban; then
    echo "fail2ban:     active"
else
    echo "fail2ban:     WARNING (not running)"
fi


if [[ "$INSTALL_OK" == false ]]; then

    echo
    echo "ERROR: XRDP services are not running correctly." >&2
    echo

    systemctl \
        --no-pager \
        --full \
        status xrdp xrdp-sesman || true

    exit 1
fi


# Confirm the listening port.

if command -v ss >/dev/null 2>&1; then

    # The output is read into a variable first. In a pipe,
    # "grep -q" exits at the first match and kills ss with
    # SIGPIPE - which "set -o pipefail" reports as a failure,
    # so the check could claim the port is closed when it is not.
    LISTENING_SOCKETS="$(ss -tln)"

    if [[ "$LISTENING_SOCKETS" =~ :${RDP_PORT}([[:space:]]|$) ]]; then
        echo "RDP port:     listening on $RDP_PORT"
    else
        echo "RDP port:     WARNING (nothing listening on $RDP_PORT yet)"
    fi

fi


echo
echo "Firewall status:"
echo

ufw status verbose


# ----------------------------------------------------------
# DONE
# ----------------------------------------------------------

echo
echo "=================================================="
echo " XRDP + XFCE installation finished"
echo
echo " OS:       ${PRETTY_NAME:-Ubuntu}"
echo " Arch:     $ARCH"
echo " RDP user: $USERNAME"
echo " RDP port: $RDP_PORT"

if [[ "$LIMIT_RDP" =~ ^[Yy]$ ]]; then
    echo " RDP IP:   $ALLOWED_IP"
else
    echo " RDP IP:   ANY"
fi

echo
echo " Connect using:"
echo "   <SERVER_IP>:$RDP_PORT"
echo
echo " Sessions are persistent."
echo " CLOSE the RDP window to keep applications running."
echo " LOGGING OUT inside XFCE ends the session and closes"
echo " everything in it."
echo
echo " AppImages are supported (FUSE 2 installed)."
echo " Remember to make them executable:"
echo "   chmod +x <file>.AppImage"
echo
echo " Useful commands:"
echo "   fail2ban-client status sshd"
echo "   fail2ban-client status xrdp"
echo "   fail2ban-client set xrdp unbanip <IP>"
echo "   xrdp-session-reset"

if [[ "$JD_MODE" == "service" ]]; then

    echo
    echo " JDownloader (headless service)"
    echo
    echo " First run is interactive. As root, run:"
    echo "   sudo -u $USERNAME java -jar $JD_DIR/JDownloader.jar"
    echo
    echo " Enter the My JDownloader credentials when asked,"
    echo " wait until the device appears on my.jdownloader.org,"
    echo " then press Ctrl+C and start the service:"
    echo "   systemctl start jdownloader"

elif [[ "$JD_MODE" == "desktop" ]]; then

    echo
    echo " JDownloader (desktop application)"
    echo
    echo " Available in the XFCE menu under Internet."
    echo " The first start asks for My JDownloader credentials."

fi

if [[ ! "$LIMIT_RDP" =~ ^[Yy]$ ]]; then
    echo
    echo " WARNING: RDP is publicly accessible."
    echo " fail2ban limits brute force attempts, but a long,"
    echo " randomly generated password remains essential."
fi

echo
echo " Recommended: reboot before the first RDP login."
echo
echo "=================================================="
