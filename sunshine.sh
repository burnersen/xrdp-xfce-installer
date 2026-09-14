#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# Sunshine on a headless server, with its own display
#
# Ubuntu 20.04+
#
# Optional companion script for install.sh.
#
# Sunshine captures a screen. A headless server has none,
# and the X server started by XRDP is not usable for this:
# its display number changes per session and it only exists
# while someone is connected.
#
# This script therefore creates a SEPARATE virtual display
# with its own XFCE desktop, and runs Sunshine against it.
#
#   Xvfb          :20   virtual screen, always running
#   xfce4-session :20   desktop on that screen
#   sunshine      :20   captures and streams it
#
# Nothing in /etc/xrdp is touched. The RDP desktop keeps
# working exactly as before, and the two desktops are
# independent of each other.
#
# Note: this is a second desktop. What you see in Moonlight
# is NOT the same desktop you see over RDP.
# ==========================================================

on_error() {
    local exit_code=$?

    echo >&2
    echo "==================================================" >&2
    echo " ERROR: Sunshine setup failed" >&2
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
echo " Sunshine with a dedicated virtual display"
echo "=================================================="
echo
echo "This creates a SECOND desktop, separate from the one"
echo "you reach over RDP. Files and settings are shared,"
echo "the running applications are not."
echo
echo "No file under /etc/xrdp is modified."
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
    echo "ERROR: This script supports Ubuntu only." >&2
    exit 1
fi

ARCH="$(dpkg --print-architecture)"

echo "Detected system:"
echo "  OS:   ${PRETTY_NAME:-Ubuntu}"
echo "  Arch: $ARCH"
echo


# ----------------------------------------------------------
# HARDWARE NOTE
#
# Without a GPU, encoding runs on the CPU. Usable for a
# desktop or video playback, not for gaming.
# ----------------------------------------------------------

if [[ ! -d /dev/dri ]]; then

    echo "NOTE: No GPU detected."
    echo "Encoding will run on the CPU. This is fine for a"
    echo "desktop, but do not expect smooth gaming."
    echo

fi


# ----------------------------------------------------------
# TARGET USER
# ----------------------------------------------------------

read -rp \
    "Username that should own the Sunshine desktop: " \
    USERNAME < /dev/tty

if [[ -z "$USERNAME" ]]; then
    echo "ERROR: No username given." >&2
    exit 1
fi

if ! id "$USERNAME" &>/dev/null; then
    echo "ERROR: User '$USERNAME' does not exist." >&2
    exit 1
fi

USER_UID="$(id -u "$USERNAME")"

if (( USER_UID < 1000 )); then
    echo "ERROR: '$USERNAME' is a system account (UID $USER_UID)." >&2
    exit 1
fi

USER_GROUP="$(id -gn "$USERNAME")"


# ----------------------------------------------------------
# DISPLAY SETTINGS
# ----------------------------------------------------------

echo

read -rp \
    "Display number for the virtual screen [20]: " \
    DISPLAY_NUM < /dev/tty

DISPLAY_NUM="${DISPLAY_NUM:-20}"

if ! [[ "$DISPLAY_NUM" =~ ^[0-9]+$ ]] ||
   (( DISPLAY_NUM < 10 || DISPLAY_NUM > 99 )); then

    echo "ERROR: Use a number between 10 and 99." >&2
    exit 1
fi

# XRDP starts counting at :10 and goes up, so a low number
# would eventually collide with an RDP session.

if (( DISPLAY_NUM < 20 )); then

    echo "ERROR: Displays below :20 are used by XRDP sessions." >&2
    echo "Pick 20 or higher." >&2
    exit 1
fi

if [[ -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ]]; then
    echo "ERROR: Display :$DISPLAY_NUM is already in use." >&2
    exit 1
fi

echo

read -rp \
    "Resolution [1920x1080]: " \
    RESOLUTION < /dev/tty

RESOLUTION="${RESOLUTION:-1920x1080}"

if ! [[ "$RESOLUTION" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]]; then
    echo "ERROR: Invalid resolution. Example: 1920x1080" >&2
    exit 1
fi


# ----------------------------------------------------------
# FIREWALL SCOPE
# ----------------------------------------------------------

echo

read -rp \
    "Restrict Moonlight access to one IPv4 address? [Y/n]: " \
    LIMIT_STREAM < /dev/tty

LIMIT_STREAM="${LIMIT_STREAM:-Y}"

ALLOWED_IP=""

if [[ "$LIMIT_STREAM" =~ ^[Yy]$ ]]; then

    while true; do

        read -rp \
            "Enter allowed public IPv4 address: " \
            ALLOWED_IP < /dev/tty

        if [[ "$ALLOWED_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            break
        fi

        echo "ERROR: Invalid IPv4 address."
        echo "Example: 203.0.113.10"

    done

elif ! [[ "$LIMIT_STREAM" =~ ^[Nn]$ ]]; then

    echo "ERROR: Please answer y or n." >&2
    exit 1

fi


# ----------------------------------------------------------
# PACKAGES
# ----------------------------------------------------------

echo
echo "[1/6] Installing the virtual display server"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    xvfb \
    x11-xserver-utils \
    x11-utils \
    dbus-x11 \
    curl \
    ca-certificates


# ----------------------------------------------------------
# SUNSHINE
#
# The official APT repository is used instead of a direct
# download: release filenames contain the version, so any
# hardcoded URL breaks with the next release.
# ----------------------------------------------------------

echo
echo "[2/6] Installing Sunshine"

if ! command -v sunshine >/dev/null 2>&1; then

    curl -1sLf \
        'https://dl.cloudsmith.io/public/lizardbyte/stable/cfg/setup/bash.deb.sh' \
        | bash

    apt-get update
    apt-get install -y sunshine

else

    echo "Sunshine is already installed."

fi

# Virtual input devices (keyboard, mouse, gamepad) require
# membership in the input group.

if getent group input >/dev/null 2>&1; then
    usermod -aG input "$USERNAME"
fi

# The package ships a per user service that would capture
# whichever display it happens to find. This setup uses its
# own service instead, so make sure the packaged one is not
# enabled.

systemctl --global disable \
    app-dev.lizardbyte.app.Sunshine.service 2>/dev/null || true


# ----------------------------------------------------------
# SERVICES
#
# Three units, started in order:
#
#   sunshine-xvfb     the virtual screen
#   sunshine-desktop  XFCE on that screen
#   sunshine-stream   Sunshine capturing it
# ----------------------------------------------------------

echo
echo "[3/6] Creating services"

# Allow the user's services to run without an active login.

loginctl enable-linger "$USERNAME" 2>/dev/null || true


cat > /etc/systemd/system/sunshine-xvfb.service <<EOF
[Unit]
Description=Virtual X display for Sunshine
After=network.target

[Service]
Type=simple
User=$USERNAME
Group=$USER_GROUP
ExecStart=/usr/bin/Xvfb :$DISPLAY_NUM -screen 0 ${RESOLUTION}x24 -ac -noreset
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF


cat > /etc/systemd/system/sunshine-desktop.service <<EOF
[Unit]
Description=XFCE desktop on the Sunshine display
After=sunshine-xvfb.service
Requires=sunshine-xvfb.service

[Service]
Type=simple
User=$USERNAME
Group=$USER_GROUP
Environment=DISPLAY=:$DISPLAY_NUM
Environment=XDG_RUNTIME_DIR=/run/user/$USER_UID
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/dbus-launch --exit-with-session /usr/bin/xfce4-session
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF


cat > /etc/systemd/system/sunshine-stream.service <<EOF
[Unit]
Description=Sunshine game stream host
After=sunshine-desktop.service
Requires=sunshine-desktop.service

[Service]
Type=simple
User=$USERNAME
Group=$USER_GROUP
Environment=DISPLAY=:$DISPLAY_NUM
Environment=XDG_RUNTIME_DIR=/run/user/$USER_UID

# The package sets CAP_SYS_ADMIN and CAP_SYS_NICE on the
# binary, but file capabilities are dropped for a service
# running under User=. Without them Sunshine cannot raise
# its thread priority and virtual input devices may fail.

AmbientCapabilities=CAP_SYS_ADMIN CAP_SYS_NICE
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_SYS_NICE

ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/sunshine
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF


chmod 0644 /etc/systemd/system/sunshine-xvfb.service
chmod 0644 /etc/systemd/system/sunshine-desktop.service
chmod 0644 /etc/systemd/system/sunshine-stream.service

systemctl daemon-reload


# ----------------------------------------------------------
# FIREWALL
#
# Moonlight needs:
#
#   TCP 47984  HTTPS
#   TCP 47989  HTTP
#   TCP 48010  RTSP
#   UDP 47998, 47999, 48000, 48002, 48010  streams
#
# TCP 47990 is the web UI and is deliberately NOT opened.
# It is reached from the server's own browser over RDP at
# https://localhost:47990, which keeps it off the Internet
# entirely.
# ----------------------------------------------------------

echo
echo "[4/6] Configuring the firewall"

if ! command -v ufw >/dev/null 2>&1; then

    echo "WARNING: UFW is not installed. Skipping firewall rules."

else

    add_rule() {

        local proto="$1"
        local port="$2"

        if [[ -n "$ALLOWED_IP" ]]; then

            ufw allow \
                from "$ALLOWED_IP" \
                to any \
                port "$port" \
                proto "$proto" \
                comment "Sunshine"

        else

            ufw allow \
                "${port}/${proto}" \
                comment "Sunshine"

        fi
    }

    add_rule tcp 47984
    add_rule tcp 47989
    add_rule tcp 48010

    for UDP_PORT in 47998 47999 48000 48002 48010; do
        add_rule udp "$UDP_PORT"
    done

    if [[ -n "$ALLOWED_IP" ]]; then
        echo "Moonlight access restricted to: $ALLOWED_IP"
    else
        echo "Moonlight ports are open to any IP."
    fi

    echo "Web UI port 47990 was NOT opened (local access only)."

fi


# ----------------------------------------------------------
# START
# ----------------------------------------------------------

echo
echo "[5/6] Starting services"

systemctl enable --now sunshine-xvfb
sleep 3
systemctl enable --now sunshine-desktop
sleep 5
systemctl enable --now sunshine-stream
sleep 5


# ----------------------------------------------------------
# VERIFY
# ----------------------------------------------------------

echo
echo "[6/6] Verifying"

SETUP_OK=true

for UNIT in sunshine-xvfb sunshine-desktop sunshine-stream; do

    if systemctl is-active --quiet "$UNIT"; then
        printf '%-20s active\n' "$UNIT:"
    else
        printf '%-20s FAILED\n' "$UNIT:"
        SETUP_OK=false
    fi

done

if [[ "$SETUP_OK" == false ]]; then

    echo
    echo "ERROR: Not all services are running." >&2
    echo "Check the logs with:" >&2
    echo "  journalctl -u sunshine-xvfb -n 30 --no-pager" >&2
    echo "  journalctl -u sunshine-desktop -n 30 --no-pager" >&2
    echo "  journalctl -u sunshine-stream -n 30 --no-pager" >&2

    exit 1
fi

# Confirm the display actually answers.

if sudo -u "$USERNAME" \
    DISPLAY=":$DISPLAY_NUM" \
    xdpyinfo >/dev/null 2>&1; then

    echo "virtual display:     :$DISPLAY_NUM responding"

else

    echo "virtual display:     WARNING (not responding yet)"

fi


# ----------------------------------------------------------
# DONE
# ----------------------------------------------------------

echo
echo "=================================================="
echo " Sunshine setup finished"
echo
echo " User:       $USERNAME"
echo " Display:    :$DISPLAY_NUM"
echo " Resolution: $RESOLUTION"

if [[ -n "$ALLOWED_IP" ]]; then
    echo " Client IP:  $ALLOWED_IP"
else
    echo " Client IP:  ANY"
fi

echo
echo " NEXT STEPS"
echo
echo " 1. Connect over RDP and open this address in the"
echo "    browser ON THE SERVER:"
echo
echo "      https://localhost:47990"
echo
echo "    Accept the certificate warning. The certificate"
echo "    is self-signed, which is expected."
echo
echo " 2. Create the Sunshine username and password on"
echo "    first visit. Write them down."
echo
echo " 3. In Moonlight on the client, add the PC manually"
echo "    using the server's public IP address."
echo
echo " 4. Enter the PIN shown by Moonlight under 'PIN' in"
echo "    the Sunshine web UI."
echo
echo " The web UI is not reachable from the Internet by"
echo " design. Open it from the server's own browser."
echo
echo " Useful commands:"
echo "   systemctl status sunshine-stream"
echo "   systemctl restart sunshine-stream"
echo "   journalctl -u sunshine-stream -n 50 --no-pager"
echo
echo " To remove everything again:"
echo "   systemctl disable --now sunshine-stream"
echo "   systemctl disable --now sunshine-desktop"
echo "   systemctl disable --now sunshine-xvfb"
echo "   apt-get remove -y sunshine"
echo
echo " The RDP desktop is unaffected either way."
echo
echo "=================================================="
