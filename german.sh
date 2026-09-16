#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# German localisation for an XRDP + XFCE server
#
# Ubuntu 20.04 and newer
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
# Keeps:
#   - the English names of the home directories
#     (Downloads, Desktop, ...), so paths other applications
#     were configured with keep working
#
# Does NOT touch:
#   - the XRDP service. Nothing is restarted here, because the
#     language only takes effect when a session STARTS.
#
# Safe to run more than once.
# ==========================================================

readonly SCRIPT_VERSION="1.1.0"

# Same location as install.sh and sunshine.sh use, so every backup
# this project makes ends up in one place.
readonly BACKUP_DIR="/root/setup-backup"


# ----------------------------------------------------------
# WARNINGS
#
# Only the language packs, the locale itself and the keyboard
# file are treated as fatal. Everything else records a warning
# and the script carries on, so one hiccup cannot leave the
# system half translated.
# ----------------------------------------------------------

declare -a WARNINGS=()

warn() {
    echo "WARNING: $*" >&2
    WARNINGS+=("$*")
}


on_error() {
    local exit_code=$?

    echo >&2
    echo "==================================================" >&2
    echo " ERROR: Localisation failed" >&2
    echo " Line:    $1" >&2
    echo " Command: $2" >&2
    echo " Exit:    $exit_code" >&2
    echo >&2
    echo " Backups are in $BACKUP_DIR" >&2
    echo "==================================================" >&2

    exit "$exit_code"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR


# ----------------------------------------------------------
# SMALL HELPERS
# ----------------------------------------------------------

# Copies a file into the backup directory before it is changed.
backup_file() {
    local path="$1"

    if [[ ! -f "$path" ]]; then
        return 0
    fi

    cp -a "$path" "$BACKUP_DIR/$(basename "$path").$TIMESTAMP"
    echo "Backup: $(basename "$path").$TIMESTAMP"
}


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
echo " German localisation for XRDP + XFCE $SCRIPT_VERSION"
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

# The header promises 20.04 and newer, so check it here instead of
# failing later on a package that does not exist. Same check as in
# install.sh and sunshine.sh.
UBUNTU_VERSION="${VERSION_ID:-}"

if [[ -z "$UBUNTU_VERSION" ]]; then
    echo "ERROR: Unable to determine the Ubuntu version." >&2
    exit 1
fi

if ! dpkg --compare-versions "$UBUNTU_VERSION" ge "20.04"; then
    echo "ERROR: Ubuntu 20.04 or newer is required." >&2
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
#
# Option 3 is German WITHOUT dead keys - useful for people who
# type a lot of quotes and backticks. It is not the Austrian
# layout; that one would be XKBLAYOUT="at".
# ----------------------------------------------------------

echo

read -rp \
    "Keyboard: [1] German (de)  [2] Swiss German (ch)  [3] German, no dead keys [1]: " \
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

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly TIMESTAMP

mkdir -p "$BACKUP_DIR"


# ----------------------------------------------------------
# LOCALE
# ----------------------------------------------------------

echo
echo "[1/4] Installing German language packs"

export DEBIAN_FRONTEND=noninteractive

# A single broken third party repository must not stop the script
# before anything has happened at all.
if ! apt-get update; then
    warn "'apt-get update' reported a problem - continuing with the package lists on disk."
fi

# Without these there is no German at all, so a failure here is fatal.
apt-get install -y \
    locales \
    console-setup \
    language-pack-de \
    language-pack-de-base

# Translations for GTK and GNOME applications. Installed ONE BY ONE
# on purpose: in a single apt call, one unavailable package stops the
# others from being installed as well.
for EXTRA_PACKAGE in language-pack-gnome-de language-pack-gnome-de-base; do

    if ! apt-get install -y "$EXTRA_PACKAGE"; then
        warn "Optional package '$EXTRA_PACKAGE' could not be installed."
    fi

done

# Make sure the locale is generated even if the language
# pack did not do it.

# "> /dev/null" instead of "grep -q": with -q, grep exits at the
# first match and kills the writer with SIGPIPE, which
# "set -o pipefail" would report as a failure. Without -q grep
# reads to the end, so the pipe closes normally.

if ! locale -a 2>/dev/null | grep -i "^de_DE.utf8$" > /dev/null; then

    backup_file /etc/locale.gen

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
        warn "German Firefox language pack could not be installed."
    fi

else

    echo "Package 'firefox-l10n-de' is not available - skipping."
    echo "It comes from Mozilla's APT repository (see install.sh)."

fi



echo
echo "[2/4] Setting system locale and time zone"

backup_file /etc/default/locale

# systemd-localed is not reachable on every system (containers, for
# example). The file it would have written can be written directly -
# and that file is what the session scripts actually read.
if ! localectl set-locale LANG=de_DE.UTF-8; then

    printf 'LANG=de_DE.UTF-8\n' > /etc/default/locale
    chmod 0644 /etc/default/locale

    warn "localectl failed - /etc/default/locale was written directly."

fi

if ! timedatectl set-timezone Europe/Berlin; then
    warn "Time zone could not be set to Europe/Berlin."
fi

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
echo "[3/4] Configuring keyboard layout"

backup_file /etc/default/keyboard

# Keep any options that are already configured - overwriting them
# with an empty value would silently remove things like
# "terminate:ctrl_alt_bksp".
XKB_OPTIONS=""

if [[ -f /etc/default/keyboard ]]; then
    XKB_OPTIONS="$(sed -n 's/^XKBOPTIONS="\(.*\)"$/\1/p' /etc/default/keyboard)"
fi

cat > /etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$XKB_LAYOUT"
XKBVARIANT="$XKB_VARIANT"
XKBOPTIONS="$XKB_OPTIONS"
BACKSPACE="guess"
EOF

chmod 0644 /etc/default/keyboard

if ! setupcon --save 2>/dev/null; then
    warn "setupcon could not apply the console keymap (harmless on a server without a console)."
fi

echo "Layout:  $XKB_LAYOUT"
echo "Variant: ${XKB_VARIANT:-none}"
echo "Options: ${XKB_OPTIONS:-none}"


# ----------------------------------------------------------
# XFCE SESSION LANGUAGE
#
# XRDP reads ~/.xsessionrc before starting the desktop, so
# the language has to be exported there. A running session
# is not affected.
# ----------------------------------------------------------

echo
echo "[4/4] Configuring German desktop for '$USERNAME'"

backup_file "$HOME_DIR/.xsessionrc"

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

# ---- Keep the existing English directory names ----
#
# Renaming Downloads to Downloads/Dokumente breaks paths that other
# applications were configured with.
#
# Writing "en_US" into ~/.config/user-dirs.locale is NOT enough: that
# file is only the marker saying which language was used last. Once
# the session runs in German the two differ - and that difference is
# exactly what triggers the renaming.
#
# The documented off switch is "enabled=False" in user-dirs.conf.
# The update is run once beforehand with LC_ALL=C so that
# user-dirs.dirs exists with English names before it is frozen.

if [[ ! -d "$HOME_DIR/.config" ]]; then
    mkdir -p "$HOME_DIR/.config"
    chown "$USERNAME:$USER_GROUP" "$HOME_DIR/.config"
fi

if command -v xdg-user-dirs-update >/dev/null 2>&1; then

    # HOME is passed explicitly. runuser does set it, but relying on
    # that would be a silent dependency - and a wrong HOME would write
    # the result into /root instead of the user's home directory.
    if ! runuser -u "$USERNAME" -- \
         env HOME="$HOME_DIR" LC_ALL=C xdg-user-dirs-update; then
        warn "xdg-user-dirs-update failed - check the home directory names yourself."
    fi

else

    warn "xdg-user-dirs-update not found - the home directory names were not checked."

fi

backup_file "$HOME_DIR/.config/user-dirs.conf"

printf 'enabled=False\n' > "$HOME_DIR/.config/user-dirs.conf"

chown "$USERNAME:$USER_GROUP" "$HOME_DIR/.config/user-dirs.conf"
chmod 0644 "$HOME_DIR/.config/user-dirs.conf"

echo "Session language configured."
echo "Existing folder names (Downloads, Desktop) are kept."


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

if (( ${#WARNINGS[@]} > 0 )); then

    echo
    echo " --------------------------------------------------"
    echo " ${#WARNINGS[@]} step(s) did not complete:"
    echo

    for WARNING in "${WARNINGS[@]}"; do
        echo "   - $WARNING"
    done

fi

echo
echo " IMPORTANT"
echo
echo " The language is applied when a session STARTS."
echo " A running session keeps the old language."
echo
echo " XRDP was deliberately NOT restarted: that would cut"
echo " any RDP connection currently open - including this"
echo " one - without making the language take effect any"
echo " sooner."
echo
echo " Reboot now, or log out inside XFCE and reconnect:"
echo "   reboot"
echo
echo " Backups from this run: $BACKUP_DIR/*.$TIMESTAMP"
echo "=================================================="
