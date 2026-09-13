#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# XRDP + XFCE Remote Desktop Installer
# Ubuntu 20.04+
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
# RDP ACCESS
#
# Restricted to one IPv4 address by default.
# ----------------------------------------------------------

echo

read -rp \
    "Restrict RDP access to one IPv4 address? [Y/n]: " \
    LIMIT_RDP < /dev/tty

LIMIT_RDP="${LIMIT_RDP:-Y}"

if [[ "$LIMIT_RDP" =~ ^[Yy]$ ]]; then

    while true; do

        read -rp \
            "Enter allowed public IPv4 address for RDP (3389): " \
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
    echo "TCP port 3389 will be accessible from the Internet."
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
# SYSTEM UPDATE
# ----------------------------------------------------------

echo
echo "[1/10] Updating system"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y


# ----------------------------------------------------------
# INSTALL CORE PACKAGES
# ----------------------------------------------------------

echo
echo "[2/10] Installing XFCE, XRDP and dependencies"

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
    wget \
    ca-certificates \
    gnupg


# ----------------------------------------------------------
# POLKIT PACKAGE
#
# Package name differs between Ubuntu releases.
# Keep it separate from the main dependency installation.
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
# XRDP CONFIGURATION
# ----------------------------------------------------------

echo
echo "[3/10] Configuring XRDP"

if getent group ssl-cert >/dev/null 2>&1; then
    usermod -aG ssl-cert xrdp
fi

systemctl enable xrdp

systemctl restart xrdp-sesman
systemctl restart xrdp


# ----------------------------------------------------------
# CREATE / CONFIGURE USER
# ----------------------------------------------------------

echo
echo "[4/10] Configuring user '$USERNAME'"

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
echo "[5/10] Configuring XFCE session"

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
echo "[6/10] Configuring polkit for XRDP"

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
echo "[7/10] Configuring UFW"

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
# Remove ALL existing UFW rules for port 3389 before adding
# the new restricted rule.
#
# This prevents an old "ALLOW Anywhere" rule from remaining.
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

    # Examples:
    #
    # allow 3389
    # allow 3389/tcp

    if [[ "$RULE" =~ ^(allow|deny|reject|limit)[[:space:]]+3389(/tcp)?([[:space:]]|$) ]]; then
        IS_RDP_RULE=true
    fi

    # Example:
    #
    # allow from 203.0.113.10 to any port 3389 proto tcp

    if [[ "$RULE" =~ to[[:space:]]+any[[:space:]]+port[[:space:]]+3389([[:space:]]|$) ]]; then
        IS_RDP_RULE=true
    fi

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
        port 3389 \
        proto tcp \
        comment "XRDP"

    echo "RDP access restricted to: $ALLOWED_IP"

else

    ufw allow \
        3389/tcp \
        comment "XRDP"

    echo "WARNING: RDP is accessible from any IP."

fi

ufw --force enable


# ----------------------------------------------------------
# BROWSERS
# ----------------------------------------------------------

echo
echo "[8/10] Installing browsers"


# ----------------------------------------------------------
# GOOGLE CHROME
#
# Google's official Linux .deb is amd64 only.
#
# On other architectures try Chromium.
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
# On modern Ubuntu versions the package may install Firefox
# through Snap.
#
# Browser installation failure is non-fatal.
# ----------------------------------------------------------

echo "Installing Firefox..."

if ! apt-get install -y firefox; then
    echo "WARNING: Firefox installation failed."
fi


# ----------------------------------------------------------
# VERIFY
# ----------------------------------------------------------

echo
echo "[9/10] Verifying installation"

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


echo
echo "Firewall status:"
echo

ufw status verbose


# ----------------------------------------------------------
# DONE
# ----------------------------------------------------------

echo
echo "[10/10] Installation completed"
echo
echo "=================================================="
echo " XRDP + XFCE installation finished"
echo
echo " OS:       ${PRETTY_NAME:-Ubuntu}"
echo " Arch:     $ARCH"
echo " RDP user: $USERNAME"
echo " RDP port: 3389"

if [[ "$LIMIT_RDP" =~ ^[Yy]$ ]]; then

    echo " RDP IP:   $ALLOWED_IP"

else

    echo " RDP IP:   ANY"
    echo
    echo " WARNING: RDP is publicly accessible."

fi

echo
echo " Recommended: reboot before the first RDP login."
echo
echo " Connect using:"
echo "   <SERVER_IP>:3389"
echo
echo "=================================================="
