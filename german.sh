#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# German localisation for an XRDP + XFCE server
#
# Ubuntu 20.04+
#
# Optional companion script for install.sh.
#
# Sets:
#   - system locale de_DE.UTF-8
#   - time zone Europe/Berlin
#   - German keyboard layout (console and X11)
#   - German XFCE session for one user
#   - German language pack for Firefox (if available)
#
# Safe to run more than once.
# ==========================================================

on_error() {
    local exit_code=$?

    echo >&2
    echo "==================================================" >&2
    echo " ERROR: Localisation failed" >&2
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
echo " German localisation for XRDP + XFCE"
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
    echo "ERROR: This script supports Ubuntu only." >&2
    exit 1
fi

echo "Detected system: ${PRETTY_NAME:-Ubuntu}"
echo


# ----------------------------------------------------------
# TARGET USER
#
# The XFCE session language is a per user setting, so the
# desktop user has to be named explicitly.
# ----------------------------------------------------------

read -rp \
    "Username whose desktop should be German: " \
    USERNAME < /dev/tty

if [[ -z "$USERNAME" ]]; then
    echo "ERROR: No username given." >&2
    exit 1
fi

if ! id "$USERNAME" &>/dev/null; then
    echo "ERROR: User '$USERNAME' does not exist." >&2
    exit 1
fi

EXISTING_UID="$(id -u "$USERNAME")"

if (( EXISTING_UID < 1000 )); then
    echo "ERROR: '$USERNAME' is a system account (UID $EXISTING_UID)." >&2
    exit 1
fi

PASSWD_ENTRY="$(getent passwd "$USERNAME")"

IFS=':' read -r _ _ _ _ _ HOME_DIR _ <<< "$PASSWD_ENTRY"

if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
    echo "ERROR: Invalid home directory for '$USERNAME': $HOME_DIR" >&2
    exit 1
fi

USER_GROUP="$(id -gn "$USERNAME")"


# ----------------------------------------------------------
# KEYBOARD LAYOUT VARIANT
# ----------------------------------------------------------

echo

read -rp \
    "Keyboard layout: [1] German (de)  [2] Swiss German (ch)  [3] Austrian (de) [1]: " \
    KB_CHOICE < /dev/tty

KB_CHOICE="${KB_CHOICE:-1}"

case "$KB_CHOICE" in
    1) XKB_LAYOUT="de"; XKB_VARIANT="" ;;
    2) XKB_LAYOUT="ch"; XKB_VARIANT="de" ;;
    3) XKB_LAYOUT="de"; XKB_VARIANT="nodeadkeys" ;;
    *)
        echo "ERROR: Please select 1, 2 or 3." >&2
        exit 1
        ;;
esac


# ----------------------------------------------------------
# LOCALE
# ----------------------------------------------------------

echo
echo "[1/5] Installing German language packs"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    language-pack-de \
    language-pack-de-base \
    language-pack-gnome-de \
    language-pack-gnome-de-base \
    locales \
    console-setup

# Make sure the locale is generated even if the language
# pack did not do it.

# "> /dev/null" instead of "grep -q": with -q, grep exits at the
# first match and kills the writer with SIGPIPE, which
# "set -o pipefail" would report as a failure. Without -q grep
# reads to the end, so the pipe closes normally.

if ! locale -a 2>/dev/null | grep -i "^de_DE.utf8$" > /dev/null; then

    sed -i 's/^# *de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen de_DE.UTF-8

fi

# Firefox from Mozilla's APT repository ships in English only.
# The language pack comes from that same repository, which
# install.sh sets up - so a missing package is not an error
# here, it just means Firefox was installed differently.

if ! command -v firefox >/dev/null 2>&1; then

    echo "Firefox is not installed - skipping its language pack."

elif apt-cache show firefox-l10n-de >/dev/null 2>&1; then

    echo "Installing German language pack for Firefox..."

    if ! apt-get install -y firefox-l10n-de; then
        echo "WARNING: German Firefox language pack could not be installed."
    fi

else

    echo "Package 'firefox-l10n-de' is not available - skipping."
    echo "It comes from Mozilla's APT repository (see install.sh)."

fi



echo
echo "[2/5] Setting system locale and time zone"

localectl set-locale LANG=de_DE.UTF-8
timedatectl set-timezone Europe/Berlin

echo "Locale:   de_DE.UTF-8"
echo "Timezone: Europe/Berlin"


# ----------------------------------------------------------
# KEYBOARD
#
# localectl set-x11-keymap is rejected on Debian based
# systems ("Setting X11 and console keymaps is not
# supported in Debian"), so the configuration file is
# written directly.
# ----------------------------------------------------------

echo
echo "[3/5] Configuring keyboard layout"

if [[ -f /etc/default/keyboard && ! -f /etc/default/keyboard.orig ]]; then
    cp /etc/default/keyboard /etc/default/keyboard.orig
fi

cat > /etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$XKB_LAYOUT"
XKBVARIANT="$XKB_VARIANT"
XKBOPTIONS=""
BACKSPACE="guess"
EOF

chmod 0644 /etc/default/keyboard

setupcon --save 2>/dev/null || true

echo "Layout:  $XKB_LAYOUT"
echo "Variant: ${XKB_VARIANT:-none}"


# ----------------------------------------------------------
# XFCE SESSION LANGUAGE
#
# XRDP reads ~/.xsessionrc before starting the desktop, so
# the language has to be exported there. A running session
# is not affected.
# ----------------------------------------------------------

echo
echo "[4/5] Configuring German desktop for '$USERNAME'"

cat > "$HOME_DIR/.xsessionrc" <<'EOF'
# German desktop session.
#
# LC_ALL is deliberately NOT set: it would override every
# individual category and break applications that expect a
# specific one.

export LANG=de_DE.UTF-8
export LANGUAGE=de_DE:de
export LC_MESSAGES=de_DE.UTF-8
EOF

chown "$USERNAME:$USER_GROUP" "$HOME_DIR/.xsessionrc"
chmod 0644 "$HOME_DIR/.xsessionrc"

# Keep the existing English directory names.
#
# Renaming Downloads to Downloads/Dokumente breaks paths
# that other applications were configured with.

mkdir -p "$HOME_DIR/.config"

if [[ ! -f "$HOME_DIR/.config/user-dirs.locale" ]]; then

    printf 'en_US\n' > "$HOME_DIR/.config/user-dirs.locale"

    chown "$USERNAME:$USER_GROUP" \
        "$HOME_DIR/.config/user-dirs.locale"

fi

chown "$USERNAME:$USER_GROUP" "$HOME_DIR/.config" 2>/dev/null || true

echo "Session language configured."
echo "Existing folder names (Downloads, Desktop) are kept."


# ----------------------------------------------------------
# RESTART SERVICES
# ----------------------------------------------------------

echo
echo "[5/5] Restarting XRDP"

systemctl restart xrdp-sesman
systemctl restart xrdp


# ----------------------------------------------------------
# DONE
# ----------------------------------------------------------

echo
echo "=================================================="
echo " German localisation finished"
echo
echo " Locale:   de_DE.UTF-8"
echo " Timezone: Europe/Berlin"
echo " Keyboard: $XKB_LAYOUT ${XKB_VARIANT:+($XKB_VARIANT)}"
echo " Desktop:  $USERNAME"
echo
echo " IMPORTANT"
echo
echo " The language is applied when a session STARTS."
echo " A running session keeps the old language."
echo
echo " Reboot now, or log out inside XFCE and reconnect:"
echo "   reboot"
echo
echo "=================================================="
