#!/usr/bin/env bash
#
# ==========================================================
#  Sunshine on a server without a screen,
#  with a second desktop of its own
#
#  Ubuntu 20.04 and newer
# ==========================================================
#
#  WHAT THIS SCRIPT BUILDS
#
#    sunshine-xorg.service      Xorg (dummy) :20   the screen
#      +- sunshine-desktop.service   XFCE on it
#           +- sunshine-stream.service   Sunshine streaming it
#
#  Plus a virtual audio output over PipeWire, because the
#  server has no sound card and the stream would be silent.
#
#  The RDP setup is not touched. A SECOND desktop appears
#  next to the one reached over RDP: same files, but separate
#  running applications.
#
#  WHY XORG AND NOT XVFB
#
#  Xvfb accepts no input devices. Sunshine creates its mouse
#  and keyboard as virtual uinput devices the moment a client
#  connects - under Xvfb those are discarded. The result would
#  be: the picture arrives, nothing can be operated. Xorg with
#  the "dummy" driver is a full X server without a graphics
#  card and picks up new input devices through udev.
#
#  IMPORTANT ON THE CLIENT (or the mouse will not move!)
#
#  In Moonlight, "optimize mouse for remote desktop" has to be
#  switched OFF. With that setting Moonlight sends absolute
#  positions, which never arrive at Sunshine.
#  The note is repeated at the end.
#
#  WHAT IS NOT TOUCHED
#
#    /etc/xrdp/ ... , /etc/X11/xorg.conf , /etc/X11/xorg.conf.d/
#
#  Every file that is modified is backed up beforehand into
#  /root/setup-backup.
# ==========================================================

set -Eeuo pipefail


# ----------------------------------------------------------
# CONSTANTS
# ----------------------------------------------------------

readonly BACKUP_DIR="/root/setup-backup"
readonly XORG_CONFIG="/etc/X11/xorg-dummy.conf"
readonly XWRAPPER_CONFIG="/etc/X11/Xwrapper.config"
readonly UINPUT_MODULE_CONFIG="/etc/modules-load.d/uinput.conf"
readonly SERVICE_DIR="/etc/systemd/system"

# Displays below :20 belong to the RDP sessions (those count up from :10).
readonly MIN_DISPLAY=20
readonly MAX_DISPLAY=99

# How long to wait for a starting X server.
readonly WAIT_MAX_SECONDS=40

# Name of the virtual audio output. The server has no sound card;
# without this device the stream would be silent.
readonly AUDIO_SINK="sunshine_sink"

# Directory for the separate profiles of the second-session launchers.
# DELIBERATELY WITHOUT A LEADING DOT: applications from a Snap package
# (on Ubuntu for example Firefox) may not read hidden directories in the
# home directory. With a dot in front, the Firefox launcher would fail.
readonly PROFILE_DIR_NAME="sunshine-profiles"


# ----------------------------------------------------------
# ERROR HANDLING
# ----------------------------------------------------------

on_error() {
    local exit_code=$?

    # If a command inside a command substitution fails, this trap runs
    # twice (subshell + main run). The subshell reports nothing.
    if [[ "$BASHPID" != "$$" ]]; then
        exit "$exit_code"
    fi

    echo >&2
    echo "==================================================" >&2
    echo " ABORTED: the setup failed." >&2
    echo " Line:    $1" >&2
    echo " Command: $2" >&2
    echo " Code:    $exit_code" >&2
    echo >&2
    echo " Backups are in $BACKUP_DIR" >&2
    echo "==================================================" >&2

    exit "$exit_code"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR


# ----------------------------------------------------------
# SMALL HELPERS
# ----------------------------------------------------------

step() {
    echo
    echo "=== $* ==="
}

note() {
    echo "    $*"
}

warn() {
    echo "    NOTE: $*"
}

backup_file() {
    local path="$1"

    if [[ ! -f "$path" ]]; then
        return 0
    fi

    cp -a "$path" "$BACKUP_DIR/$(basename "$path").$TIMESTAMP"
    note "Backup: $(basename "$path").$TIMESTAMP"
}

# Waits until the X server on the display answers.
wait_for_screen() {
    local second

    for (( second = 1; second <= WAIT_MAX_SECONDS; second++ )); do

        if DISPLAY=":$DISPLAY_NUM" xdpyinfo >/dev/null 2>&1; then
            echo
            return 0
        fi

        printf '.'
        sleep 1

    done

    echo
    return 1
}


# ----------------------------------------------------------
# PRE-FLIGHT CHECKS
# ----------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run as root (sudo -i)." >&2
    exit 1
fi

if ! true </dev/tty 2>/dev/null; then
    echo "ERROR: The script asks questions and needs a terminal." >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "ERROR: /etc/os-release not found." >&2
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "ERROR: This script is written for Ubuntu." >&2
    exit 1
fi

# Without XFCE there is nothing to stream. Better to stop here than
# halfway through the installation.
if [[ ! -x /usr/bin/xfce4-session ]]; then
    echo "ERROR: /usr/bin/xfce4-session not found." >&2
    echo "This script requires an existing XFCE desktop." >&2
    echo "Install it with:  apt-get install -y xfce4" >&2
    exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly TIMESTAMP

echo "=================================================="
echo " Set up Sunshine with a desktop of its own"
echo "=================================================="
echo
echo " System:       ${PRETTY_NAME:-Ubuntu}"
echo " Architecture: $(dpkg --print-architecture)"
echo
echo " A SECOND desktop is created next to the one reached"
echo " over RDP. The files are the same, the running"
echo " applications are not. The RDP setup is not changed."
echo

if [[ ! -d /dev/dri ]]; then
    echo " Note: no graphics card found. The picture is encoded"
    echo " by the processor. That is fine for a desktop and for"
    echo " video, but not for gaming."
    echo
fi


# ----------------------------------------------------------
# QUESTIONS
# ----------------------------------------------------------

read -rp "User the Sunshine desktop belongs to: " \
    USERNAME < /dev/tty

if [[ -z "$USERNAME" ]]; then
    echo "ERROR: No user given." >&2
    exit 1
fi

if ! id "$USERNAME" >/dev/null 2>&1; then
    echo "ERROR: User '$USERNAME' does not exist." >&2
    exit 1
fi

USER_UID="$(id -u "$USERNAME")"

if (( USER_UID < 1000 )); then
    echo "ERROR: '$USERNAME' is a system account (UID $USER_UID)." >&2
    exit 1
fi

USER_GROUP="$(id -gn "$USERNAME")"
USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"

if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    echo "ERROR: Home directory of '$USERNAME' not found." >&2
    exit 1
fi

readonly USERNAME USER_UID USER_GROUP USER_HOME

echo

read -rp "Display number [$MIN_DISPLAY]: " \
    DISPLAY_NUM < /dev/tty

DISPLAY_NUM="${DISPLAY_NUM:-$MIN_DISPLAY}"

if ! [[ "$DISPLAY_NUM" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Please enter a number." >&2
    exit 1
fi

if (( DISPLAY_NUM < MIN_DISPLAY || DISPLAY_NUM > MAX_DISPLAY )); then
    echo "ERROR: Please use a number between $MIN_DISPLAY and $MAX_DISPLAY." >&2
    echo "Lower numbers belong to the RDP sessions." >&2
    exit 1
fi

if [[ -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ]]; then
    echo "ERROR: Display :$DISPLAY_NUM is already in use." >&2
    exit 1
fi

readonly DISPLAY_NUM

echo

read -rp "Resolution [1920x1080]: " RESOLUTION < /dev/tty

RESOLUTION="${RESOLUTION:-1920x1080}"

if ! [[ "$RESOLUTION" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]]; then
    echo "ERROR: Invalid resolution. Example: 1920x1080" >&2
    exit 1
fi

SCREEN_WIDTH="${RESOLUTION%x*}"
SCREEN_HEIGHT="${RESOLUTION#*x}"

readonly RESOLUTION SCREEN_WIDTH SCREEN_HEIGHT

echo

read -rp "Restrict access to a single IPv4 address? [Y/n]: " \
    ANSWER_FIREWALL < /dev/tty

ANSWER_FIREWALL="${ANSWER_FIREWALL:-J}"

ALLOWED_IP=""

if [[ "$ANSWER_FIREWALL" =~ ^[JjYy]$ ]]; then

    while true; do

        read -rp "Allowed public IPv4 address: " \
            ALLOWED_IP < /dev/tty

        if [[ "$ALLOWED_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            break
        fi

        echo "Invalid. Example: 203.0.113.10"

    done

elif ! [[ "$ANSWER_FIREWALL" =~ ^[Nn]$ ]]; then

    echo "ERROR: Please answer y or n." >&2
    exit 1

fi

readonly ALLOWED_IP

echo
echo "Some applications (browsers, mail clients) run only ONCE"
echo "per user. If one is already open on the RDP desktop,"
echo "starting it here does nothing. Separate launchers with"
echo "their own profile can be created to work around that."
echo

read -rp "Create such second-session launchers? [Y/n]: " \
    ANSWER_LAUNCHERS < /dev/tty

ANSWER_LAUNCHERS="${ANSWER_LAUNCHERS:-J}"

if [[ "$ANSWER_LAUNCHERS" =~ ^[JjYy]$ ]]; then
    CREATE_LAUNCHERS=true
elif [[ "$ANSWER_LAUNCHERS" =~ ^[Nn]$ ]]; then
    CREATE_LAUNCHERS=false
else
    echo "ERROR: Please answer y or n." >&2
    exit 1
fi

readonly CREATE_LAUNCHERS

mkdir -p "$BACKUP_DIR"


# ----------------------------------------------------------
# 1 - PACKAGES
# ----------------------------------------------------------

step "[1/10] Installing packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update

# xserver-xorg-video-dummy     the screen without a graphics card
# xserver-xorg-input-libinput  so input devices are accepted
# x11-utils / xinput           for the checks at the end
# python3-evdev                creates the test device for the acceptance check
apt-get install -y \
    xserver-xorg-core \
    xserver-xorg-video-dummy \
    xserver-xorg-input-libinput \
    x11-xserver-utils \
    x11-utils \
    xinput \
    python3-evdev \
    dbus-x11 \
    curl \
    ca-certificates


# ----------------------------------------------------------
# 2 - SUNSHINE
#
# The vendor's package repository is used instead of a fixed
# download URL: release file names contain the version and
# would break with the next release.
# ----------------------------------------------------------

step "[2/10] Installing Sunshine"

if command -v sunshine >/dev/null 2>&1; then

    note "Sunshine is already installed."

else

    curl -1sLf \
        'https://dl.cloudsmith.io/public/lizardbyte/stable/cfg/setup/bash.deb.sh' \
        | bash

    apt-get update
    apt-get install -y sunshine

fi

# The bundled user service would look for whichever display it can
# find. This setup uses its own services, so disable the bundled one.
systemctl --global disable \
    app-dev.lizardbyte.app.Sunshine.service >/dev/null 2>&1 || true


# ----------------------------------------------------------
# 3 - INPUT DEVICES
#
# Without the uinput module there is no /dev/uinput, and without
# that Sunshine cannot create a virtual mouse. The entry in
# modules-load.d makes sure it survives a reboot.
# ----------------------------------------------------------

step "[3/10] Preparing input devices"

modprobe uinput 2>/dev/null || true

echo uinput > "$UINPUT_MODULE_CONFIG"

if [[ ! -e /dev/uinput ]]; then
    echo "ERROR: /dev/uinput is missing. Without it there is no input." >&2
    echo "Does this machine's provider allow custom kernel modules?" >&2
    exit 1
fi

note "$(ls -l /dev/uinput)"

if getent group input >/dev/null 2>&1; then

    if [[ " $(id -nG "$USERNAME") " == *" input "* ]]; then
        note "$USERNAME is in the input group."
    else
        usermod -aG input "$USERNAME"
        note "$USERNAME added to the input group."
    fi

fi


# ----------------------------------------------------------
# 4 - SCREEN CONFIGURATION
#
# A dedicated file name on purpose: only this script's own Xorg
# call reads this file. A file called xorg.conf, or a snippet in
# xorg.conf.d, would also be read by the xrdp sessions and could
# break RDP access.
# ----------------------------------------------------------

step "[4/10] Setting up the screen"

backup_file "$XORG_CONFIG"

# The timings of a modeline depend on the resolution. A fixed value
# would only be correct for 1920x1080 and would produce a wrong
# picture for any other size, so cvt calculates a matching one.
MODELINE=""
MODE_NAME="${SCREEN_WIDTH}x${SCREEN_HEIGHT}"

if command -v cvt >/dev/null 2>&1; then
    MODELINE="$(cvt "$SCREEN_WIDTH" "$SCREEN_HEIGHT" 60 \
        | grep '^Modeline' || true)"
fi

if [[ -n "$MODELINE" ]]; then

    # cvt names the mode for example "1920x1080_60.00" - that exact
    # name has to appear again below under "Modes".
    MODE_NAME="$(awk '{ gsub(/"/, "", $2); print $2 }' <<< "$MODELINE")"
    note "Modeline calculated: $MODE_NAME"

else

    # Fallback if cvt is missing: standard values for 1920x1080.
    MODELINE='Modeline "1920x1080" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync'
    MODE_NAME="1920x1080"
    warn "cvt not found - falling back to 1920x1080."

fi

readonly MODELINE MODE_NAME

cat > "$XORG_CONFIG" <<EOF
# Virtual screen for Sunshine on display :$DISPLAY_NUM.
# Created on $(date '+%Y-%m-%d %H:%M').
#
# This file is read ONLY by this setup's own Xorg call
# (-config $(basename "$XORG_CONFIG")).
# It must NOT be named xorg.conf and must NOT live in xorg.conf.d.

Section "ServerFlags"
    # MUST stay "true". Sunshine creates mouse and keyboard as uinput
    # devices only when a client connects. With "false" - as many
    # headless guides recommend - they are discarded and nothing can
    # be operated.
    Option "AutoAddDevices" "true"
EndSection

Section "Device"
    Identifier  "DummyDevice"
    Driver      "dummy"
    VideoRam    256000
EndSection

Section "Monitor"
    Identifier  "DummyMonitor"
    HorizSync   5.0 - 1000.0
    VertRefresh 5.0 - 200.0
    $MODELINE
EndSection

Section "Screen"
    Identifier   "DummyScreen"
    Device       "DummyDevice"
    Monitor      "DummyMonitor"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Modes   "$MODE_NAME"
        Virtual $SCREEN_WIDTH $SCREEN_HEIGHT
    EndSubSection
EndSection

Section "ServerLayout"
    Identifier "DummyLayout"
    Screen 0 "DummyScreen"
EndSection
EOF

# Verify the file is complete. A half written file would otherwise
# only show up once the screen looks odd.
SECTION_COUNT="$(grep -c '^Section' "$XORG_CONFIG" || true)"
ENDSECTION_COUNT="$(grep -c '^EndSection' "$XORG_CONFIG" || true)"

if (( SECTION_COUNT != 5 || ENDSECTION_COUNT != 5 )); then
    echo "ERROR: $XORG_CONFIG is incomplete" >&2
    echo "(Section: $SECTION_COUNT, EndSection: $ENDSECTION_COUNT, expected 5 each)." >&2
    exit 1
fi

note "$XORG_CONFIG written and verified."

# Without allowed_users=anybody a service user may not start an X
# server. Only this single line is touched - the file can contain
# further entries that xrdp needs.
backup_file "$XWRAPPER_CONFIG"

if [[ ! -f "$XWRAPPER_CONFIG" ]]; then

    printf 'allowed_users=anybody\n' > "$XWRAPPER_CONFIG"
    note "$XWRAPPER_CONFIG created."

elif grep -q '^allowed_users=anybody' "$XWRAPPER_CONFIG"; then

    note "Start permission is already correct."

elif grep -q '^allowed_users=' "$XWRAPPER_CONFIG"; then

    sed -i 's/^allowed_users=.*/allowed_users=anybody/' "$XWRAPPER_CONFIG"
    note "Start permission changed to 'anybody'."

else

    printf 'allowed_users=anybody\n' >> "$XWRAPPER_CONFIG"
    note "Start permission added."

fi


# ----------------------------------------------------------
# 5 - AUDIO
#
# The server has no sound card. Without an audio system and
# without an output device, applications would have nowhere to
# play to and Sunshine nothing to capture - the stream would be
# silent.
#
# PipeWire provides both: the audio system and a virtual output.
# Because it is the only output device, it becomes the default
# on its own; applications find it without further setup.
# ----------------------------------------------------------

step "[5/10] Setting up audio"

apt-get install -y \
    pipewire \
    pipewire-pulse \
    wireplumber \
    pulseaudio-utils

# Call systemctl and pactl on behalf of the user. Both need that
# user's runtime directory, or they will not find their services.
#
# runuser instead of sudo: it belongs to util-linux and is present on
# every system, while sudo is a separate package.
as_user() {
    runuser -u "$USERNAME" -- env \
        XDG_RUNTIME_DIR="/run/user/$USER_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
        "$@"
}

# Create the virtual output permanently. A "pactl load-module" would
# be gone again after the next reboot.
PIPEWIRE_CONFIG_DIR="$USER_HOME/.config/pipewire/pipewire.conf.d"

mkdir -p "$PIPEWIRE_CONFIG_DIR"

cat > "$PIPEWIRE_CONFIG_DIR/99-sunshine-sink.conf" <<EOF
# Virtual audio output for Sunshine.
# Created on $(date '+%Y-%m-%d %H:%M').
context.objects = [
    {   factory = adapter
        args = {
            factory.name     = support.null-audio-sink
            node.name        = "$AUDIO_SINK"
            node.description = "Sunshine Audio"
            media.class      = Audio/Sink
            object.linger    = true
            audio.position   = [ FL FR ]
        }
    }
]
EOF

chown -R "$USERNAME:$USER_GROUP" "$USER_HOME/.config/pipewire"

# Enable the user's audio services. The add-wants part is required
# because they otherwise hang off graphical-session.target - and that
# is never reached when the desktop runs as a system service.
for AUDIO_SERVICE in pipewire.socket pipewire-pulse.socket wireplumber.service; do
    as_user systemctl --user enable "$AUDIO_SERVICE" >/dev/null 2>&1 || true
done

for AUDIO_SERVICE in pipewire.service pipewire-pulse.service wireplumber.service; do
    as_user systemctl --user add-wants default.target "$AUDIO_SERVICE" \
        >/dev/null 2>&1 || true
done

as_user systemctl --user daemon-reload >/dev/null 2>&1 || true

for AUDIO_SERVICE in pipewire pipewire-pulse wireplumber; do
    as_user systemctl --user restart "$AUDIO_SERVICE" >/dev/null 2>&1 || true
done

# PipeWire needs a moment before the device shows up.
sleep 4

AUDIO_SINKS="$(as_user pactl list short sinks 2>/dev/null || true)"

if [[ "$AUDIO_SINKS" == *"$AUDIO_SINK"* ]]; then
    note "Audio output '$AUDIO_SINK' is present."
else
    warn "Audio output '$AUDIO_SINK' not visible yet."
    warn "It should appear after a reboot of the server."
fi

# Tell Sunshine which output to capture.
SUNSHINE_CONFIG="$USER_HOME/.config/sunshine/sunshine.conf"

mkdir -p "$(dirname "$SUNSHINE_CONFIG")"

if [[ ! -f "$SUNSHINE_CONFIG" ]]; then
    : > "$SUNSHINE_CONFIG"
fi

backup_file "$SUNSHINE_CONFIG"

if grep -q '^audio_sink' "$SUNSHINE_CONFIG"; then
    sed -i "s/^audio_sink.*/audio_sink = $AUDIO_SINK/" "$SUNSHINE_CONFIG"
else
    printf 'audio_sink = %s\n' "$AUDIO_SINK" >> "$SUNSHINE_CONFIG"
fi

chown -R "$USERNAME:$USER_GROUP" "$USER_HOME/.config/sunshine"

note "Written to sunshine.conf: audio_sink = $AUDIO_SINK"


# ----------------------------------------------------------
# 6 - SERVICES
# ----------------------------------------------------------

step "[6/10] Creating services"

# An earlier setup using Xvfb would fight over the same display.
if [[ -f "$SERVICE_DIR/sunshine-xvfb.service" ]]; then

    warn "Old Xvfb service found - it is being disabled."
    systemctl disable --now sunshine-xvfb >/dev/null 2>&1 || true
    mv "$SERVICE_DIR/sunshine-xvfb.service" \
       "$BACKUP_DIR/sunshine-xvfb.service.replaced.$TIMESTAMP"

fi

# So the user's services may run without an active login.
# Side effect: this is what creates /run/user/<UID>, which the two
# services below need as XDG_RUNTIME_DIR.
loginctl enable-linger "$USERNAME" >/dev/null 2>&1 || true

for ATTEMPT in 1 2 3 4 5; do
    [[ -d "/run/user/$USER_UID" ]] && break
    sleep 1
done

if [[ ! -d "/run/user/$USER_UID" ]]; then
    warn "/run/user/$USER_UID is missing - the desktop may"
    warn "fail on its first start. Reboot the server if needed."
fi

cat > "$SERVICE_DIR/sunshine-xorg.service" <<EOF
[Unit]
Description=Xorg (dummy) as the screen for Sunshine
After=network.target

[Service]
Type=simple
User=$USERNAME
Group=$USER_GROUP
ExecStart=/usr/bin/Xorg :$DISPLAY_NUM -config $(basename "$XORG_CONFIG") -nolisten tcp -noreset -ac
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > "$SERVICE_DIR/sunshine-desktop.service" <<EOF
[Unit]
Description=XFCE desktop on the Sunshine screen
After=sunshine-xorg.service
Requires=sunshine-xorg.service

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

cat > "$SERVICE_DIR/sunshine-stream.service" <<EOF
[Unit]
Description=Sunshine (screen streaming)
After=sunshine-desktop.service
Requires=sunshine-desktop.service

[Service]
Type=simple
User=$USERNAME
Group=$USER_GROUP
Environment=DISPLAY=:$DISPLAY_NUM
Environment=XDG_RUNTIME_DIR=/run/user/$USER_UID

# Sunshine would like its threads treated with priority. Under User=
# the file capabilities of the binary are dropped, so both are set
# here: the capability itself and the matching limit.
AmbientCapabilities=CAP_SYS_NICE
CapabilityBoundingSet=CAP_SYS_NICE
LimitNICE=-15

ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/sunshine
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$SERVICE_DIR"/sunshine-xorg.service \
           "$SERVICE_DIR"/sunshine-desktop.service \
           "$SERVICE_DIR"/sunshine-stream.service

systemctl daemon-reload

note "sunshine-xorg, sunshine-desktop, sunshine-stream created."


# ----------------------------------------------------------
# 7 - FIREWALL
#
# Moonlight needs:
#   TCP 47984 (pairing), 47989 (control), 48010 (RTSP)
#   UDP 47998, 47999, 48000, 48002, 48010 (video and audio)
#
# Port 47990 is the web interface and is DELIBERATELY not
# opened: it is the only way to reconfigure Sunshine. It is
# operated from the server itself.
# ----------------------------------------------------------

step "[7/10] Configuring the firewall"

if ! command -v ufw >/dev/null 2>&1; then

    warn "ufw is not installed - no rules were set."

else

    add_rule() {
        local protocol="$1"
        local port="$2"

        if [[ -n "$ALLOWED_IP" ]]; then
            ufw allow from "$ALLOWED_IP" to any port "$port" \
                proto "$protocol" comment "Sunshine" >/dev/null
        else
            ufw allow "${port}/${protocol}" comment "Sunshine" >/dev/null
        fi
    }

    for PORT in 47984 47989 48010; do
        add_rule tcp "$PORT"
    done

    for PORT in 47998 47999 48000 48002 48010; do
        add_rule udp "$PORT"
    done

    if [[ -n "$ALLOWED_IP" ]]; then
        note "Access restricted to $ALLOWED_IP"
    else
        note "Access from any address."
    fi

    note "Port 47990 (web interface) stays closed - that is intended."

fi


# ----------------------------------------------------------
# 8 - START
# ----------------------------------------------------------

step "[8/10] Starting the services"

systemctl enable --now sunshine-xorg >/dev/null 2>&1

note "Waiting for the screen"

if ! wait_for_screen; then
    echo "ERROR: Display :$DISPLAY_NUM does not answer." >&2
    echo "  journalctl -u sunshine-xorg -n 40 --no-pager" >&2
    exit 1
fi

systemctl enable --now sunshine-desktop >/dev/null 2>&1
sleep 6
systemctl enable --now sunshine-stream >/dev/null 2>&1
sleep 8


# ----------------------------------------------------------
# 9 - ACCEPTANCE CHECK
#
# The proof is produced here: a uinput device of our own. If it
# shows up in the device list, the screen accepts input - without
# anyone having to start a stream.
# ----------------------------------------------------------

step "[9/10] Acceptance check"

ALL_GOOD=true

for SERVICE in sunshine-xorg sunshine-desktop sunshine-stream; do

    if systemctl is-active --quiet "$SERVICE"; then
        printf '    %-20s running\n' "$SERVICE:"
    else
        printf '    %-20s NOT RUNNING\n' "$SERVICE:"
        ALL_GOOD=false
    fi

done

# No "exit" in the awk and no "head": a reader that closes the pipe
# early kills the writer with SIGPIPE (code 141), which together with
# "set -o pipefail" would wrongly count as a failure.
SCREEN_SIZE="$(DISPLAY=":$DISPLAY_NUM" xdpyinfo \
    | awk '/dimensions:/ { print $2 }')"

note "Screen size: ${SCREEN_SIZE:-unknown}"

python3 - <<'PYTHON' &
import time
from evdev import UInput, ecodes as e

with UInput({e.EV_KEY: [e.BTN_LEFT], e.EV_REL: [e.REL_X, e.REL_Y]},
            name="Sunshine-Input-Test"):
    time.sleep(15)
PYTHON

TEST_PROCESS=$!
sleep 4

# Deliberately checked without a pipe: "grep -q" exits at the first
# match, which under "set -o pipefail" would make the result falsely
# negative.
DEVICE_LIST="$(DISPLAY=":$DISPLAY_NUM" xinput list)"

if [[ "$DEVICE_LIST" == *"Sunshine-Input-Test"* ]]; then
    note "Input test: PASSED"
else
    note "Input test: FAILED"
    ALL_GOOD=false
fi

kill "$TEST_PROCESS" 2>/dev/null || true
wait "$TEST_PROCESS" 2>/dev/null || true

# Verify audio. Without an output device the stream stays silent.
AUDIO_SINKS_NOW="$(as_user pactl list short sinks 2>/dev/null || true)"

if [[ "$AUDIO_SINKS_NOW" == *"$AUDIO_SINK"* ]]; then
    note "Audio test: PASSED ($AUDIO_SINK present)"
else
    note "Audio test: output '$AUDIO_SINK' still missing"
    warn "Not fatal - this usually sorts itself out after a reboot."
fi


# ----------------------------------------------------------
# 10 - SECOND-SESSION LAUNCHERS
#
# Applications such as browsers allow only one instance per
# user. If one is already running on the RDP desktop, a second
# call simply hands its request over there - and on this desktop
# nothing appears to happen.
#
# The remedy is a separate profile directory per application.
# ----------------------------------------------------------

step "[10/10] Launchers for second sessions"

if [[ "$CREATE_LAUNCHERS" != true ]]; then

    note "Skipped, as requested."

else

    LAUNCHER_DIR="$USER_HOME/.local/share/applications"
    PROFILE_BASE="$USER_HOME/$PROFILE_DIR_NAME"

    mkdir -p "$LAUNCHER_DIR" "$PROFILE_BASE"

    CREATED_LAUNCHERS=0

    # Creates a launcher if the application is present.
    #   $1 command, $2 display name, $3 extra arguments, $4 icon
    create_launcher() {
        local program="$1"
        local display_name="$2"
        local arguments="$3"
        local icon="$4"

        if ! command -v "$program" >/dev/null 2>&1; then
            return 0
        fi

        local path="$LAUNCHER_DIR/${program}-second-session.desktop"

        cat > "$path" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$display_name (second session)
Comment=Separate profile, runs next to an already open session
Exec=$program $arguments
Icon=$icon
Terminal=false
Categories=Network;
EOF

        chmod 0644 "$path"
        note "Launcher created: $display_name"
        CREATED_LAUNCHERS=$(( CREATED_LAUNCHERS + 1 ))
    }

    # Chrome and relatives: a separate data directory is enough.
    create_launcher google-chrome "Google Chrome" \
        "--user-data-dir=$PROFILE_BASE/google-chrome" "google-chrome"

    create_launcher google-chrome-stable "Google Chrome" \
        "--user-data-dir=$PROFILE_BASE/google-chrome" "google-chrome"

    create_launcher chromium "Chromium" \
        "--user-data-dir=$PROFILE_BASE/chromium" "chromium"

    create_launcher chromium-browser "Chromium" \
        "--user-data-dir=$PROFILE_BASE/chromium" "chromium-browser"

    create_launcher microsoft-edge "Microsoft Edge" \
        "--user-data-dir=$PROFILE_BASE/edge" "microsoft-edge"

    create_launcher brave-browser "Brave" \
        "--user-data-dir=$PROFILE_BASE/brave" "brave-browser"

    create_launcher vivaldi-stable "Vivaldi" \
        "--user-data-dir=$PROFILE_BASE/vivaldi" "vivaldi"

    create_launcher code "Visual Studio Code" \
        "--user-data-dir=$PROFILE_BASE/vscode" "code"

    # Firefox and Thunderbird additionally need --no-remote, otherwise
    # they hand the call over despite the separate profile.
    create_launcher firefox "Firefox" \
        "--no-remote --profile $PROFILE_BASE/firefox" "firefox"

    create_launcher thunderbird "Thunderbird" \
        "--no-remote --profile $PROFILE_BASE/thunderbird" "thunderbird"

    chown -R "$USERNAME:$USER_GROUP" "$LAUNCHER_DIR" "$PROFILE_BASE"

    # So the new entries show up in the menu right away.
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$LAUNCHER_DIR" >/dev/null 2>&1 || true
    fi

    if (( CREATED_LAUNCHERS == 0 )); then
        note "None of the known applications found - nothing created."
    else
        note "$CREATED_LAUNCHERS launchers are in the menu under 'Internet'."
    fi

    echo
    note "Limits of this approach, so it does not surprise you later:"
    note "- The launchers appear in BOTH menus (same home directory)."
    note "- The second profile is empty: own bookmarks, own logins."
    note "- Not every application can be separated this way. JDownloader,"
    note "  pCloud and similar lock themselves with their own files and"
    note "  can only be run on ONE desktop."
    note "- The simplest alternative remains: close the application on"
    note "  the other desktop."

fi


# ----------------------------------------------------------
# RESULT
# ----------------------------------------------------------

echo
echo "=================================================="

if [[ "$ALL_GOOD" == true ]]; then
    echo " DONE"
else
    echo " DONE, BUT WITH PROBLEMS (see above)"
fi

echo "=================================================="
echo
echo " User:        $USERNAME"
echo " Display:     :$DISPLAY_NUM"
echo " Resolution:  $RESOLUTION"

if [[ -n "$ALLOWED_IP" ]]; then
    echo " Allowed IP:  $ALLOWED_IP"
else
    echo " Allowed IP:  any"
fi

echo
echo " +----------------------------------------------+"
echo " |  IMPORTANT FOR MOONLIGHT                     |"
echo " |                                              |"
echo " |  In the client settings,                     |"
echo " |                                              |"
echo " |    'optimize mouse for remote desktop'       |"
echo " |                                              |"
echo " |  has to be switched OFF. Otherwise Moonlight |"
echo " |  sends absolute positions that never arrive  |"
echo " |  here - the picture runs, but the pointer    |"
echo " |  does not move.                              |"
echo " +----------------------------------------------+"
echo
echo " NEXT STEPS"
echo
echo " 1. Open the web interface on the server:"
echo "      https://localhost:47990"
echo "    Either from a browser on the RDP desktop, or"
echo "    from outside through a tunnel:"
echo "      ssh -L 47990:localhost:47990 root@<server>"
echo
echo "    The certificate warning is expected (self-signed)."
echo
echo " 2. On the first visit, set a user name and password"
echo "    for Sunshine and write them down."
echo
echo " 3. In Moonlight, add the machine manually using its"
echo "    public address."
echo
echo " 4. Open the PIN page of the web interface BEFORE"
echo "    clicking connect in Moonlight. Otherwise the"
echo "    attempts expire and block each other (error 409)."
echo
echo " USEFUL COMMANDS"
echo "   systemctl status sunshine-stream"
echo "   systemctl restart sunshine-stream"
echo "   journalctl -u sunshine-stream -n 50 --no-pager"
echo
echo "   Show the devices while a client is connected:"
echo "     DISPLAY=:$DISPLAY_NUM xinput list"
echo
echo "   Check the audio output (as $USERNAME):"
echo "     XDG_RUNTIME_DIR=/run/user/$USER_UID pactl list short sinks"
echo
echo " REMOVING EVERYTHING AGAIN"
echo "   systemctl disable --now sunshine-stream sunshine-desktop sunshine-xorg"
echo "   rm -f $SERVICE_DIR/sunshine-{xorg,desktop,stream}.service"
echo "   systemctl daemon-reload"
echo "   apt-get remove -y sunshine"
echo
echo " RDP access is not affected in any case."
echo
echo " Backups from this run: $BACKUP_DIR/*.$TIMESTAMP"
echo "=================================================="

[[ "$ALL_GOOD" == true ]]
