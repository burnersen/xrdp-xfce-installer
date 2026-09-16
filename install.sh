#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# XRDP + XFCE Remote Desktop Installer
#
# Ubuntu 20.04+
# Verified against Ubuntu 24.04 LTS (xrdp 0.9.24)
#                  Ubuntu 26.04 LTS (xrdp 0.10.1)
#
# Features:
#   - XFCE desktop reachable over RDP
#   - Persistent sessions (reconnect from any device/IP)
#   - Custom RDP port, checked against ports already in use
#   - UFW firewall, enabled BEFORE XRDP is installed
#   - fail2ban for SSH and XRDP, verified after installation
#   - Optional fast DNS resolvers, with automatic rollback
#   - Optional: install updates only at boot, never while working
#   - Google Chrome and Firefox (Firefox from Mozilla APT, not Snap)
#   - Optional: JDownloader 2 (desktop app or headless service)
# ==========================================================

readonly INSTALLER_VERSION="2.1.1"

readonly DNS_PRIMARY="1.1.1.1"
readonly DNS_SECONDARY="8.8.8.8"

readonly MIN_PASSWORD_LENGTH_RESTRICTED=8
readonly MIN_PASSWORD_LENGTH_PUBLIC=12

readonly MIN_UNPRIVILEGED_PORT=1024
readonly DEFAULT_RDP_PORT=3389

readonly SESMAN_LOG="/var/log/xrdp-sesman.log"
readonly XRDP_FILTER="/etc/fail2ban/filter.d/xrdp-sesman.conf"
readonly JD_DIR="/opt/jdownloader"

readonly BOOT_UPDATE_SCRIPT="/usr/local/bin/xrdp-boot-update"
readonly BOOT_UPDATE_SERVICE="/etc/systemd/system/xrdp-boot-update.service"
readonly BOOT_UPDATE_LOG="/var/log/xrdp-boot-update.log"

# A downloaded JDownloader.jar is always larger than this.
# Anything smaller is an error page, not a program.
readonly MIN_JAR_SIZE_BYTES=100000

# Ubuntu releases this installer has actually been tried on.
readonly FIRST_VERIFIED_UBUNTU="24.04"


# ----------------------------------------------------------
# WARNINGS
#
# Only the desktop itself, the user account and the firewall
# are treated as fatal. Everything else records a warning and
# the installation continues, so a temporary problem with one
# download cannot leave a half configured server behind.
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
echo " XRDP + XFCE Remote Desktop Installer $INSTALLER_VERSION"
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

if ! dpkg --compare-versions "$UBUNTU_VERSION" ge "$FIRST_VERIFIED_UBUNTU"; then
    echo "NOTE: This installer is verified on Ubuntu $FIRST_VERIFIED_UBUNTU and newer."
    echo "      It should work on $UBUNTU_VERSION, but has not been tested there."
    echo
fi


# ----------------------------------------------------------
# NON INTERACTIVE PACKAGE HANDLING
#
# needrestart (Ubuntu 22.04 and newer) asks which services to
# restart after an upgrade. That dialog ignores
# DEBIAN_FRONTEND and makes the installation look frozen.
# NEEDRESTART_MODE=a restarts the affected services without
# asking. Restarting sshd does not drop an existing SSH
# connection, so this is safe here.
# ----------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a


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


# Prints the "ss" line of whatever listens on the given TCP
# port, or nothing at all if the port is free.

listener_on_port() {
    local port="$1"

    LC_ALL=C ss -tlnp 2>/dev/null | awk -v wanted="$port" '
        NR > 1 {
            address = $4
            sub(/.*:/, "", address)
            if (address == wanted) {
                print
            }
        }'
}


# Set a key in an INI style file, inside a named section.
#
# Replaces the first active key of that section, uncomments a
# commented one, or inserts the key at the end of the section
# if it is missing.
#
# The section matters. xrdp.ini contains several "port=" lines:
# the listening port in [Globals], plus per module values such
# as "port=-1" in [Xvnc] and "port=ask3389" in [neutrinordp-any].
# Appending a missing key to the END of the file would place it
# in whatever section happens to come last, where it has no
# effect at all.

set_ini_key() {

    local file="$1"
    local section="$2"
    local key="$3"
    local value="$4"
    local temp_file

    if [[ ! -f "$file" ]]; then
        warn "$file not found - skipping $key."
        return 1
    fi

    if ! temp_file="$(mktemp)"; then
        warn "Could not create a temporary file for $file."
        return 1
    fi

    # The file is read twice: the first pass decides what has to
    # happen, the second pass writes the result.
    if ! awk -v section="$section" -v key="$key" -v value="$value" '

        BEGIN {
            active_pattern    = "^[ \t]*" key "[ \t]*="
            commented_pattern = "^[ \t]*[#;][ \t]*" key "[ \t]*="
        }

        FNR == NR {

            if ($0 ~ /^[ \t]*\[/) {

                name = $0
                sub(/^[ \t]*\[[ \t]*/, "", name)
                sub(/[ \t]*\].*$/, "", name)

                if (tolower(name) == tolower(section) && !section_found) {
                    in_section    = 1
                    section_found = 1
                    section_end   = FNR
                } else {
                    in_section = 0
                }

                next
            }

            if (in_section) {

                if ($0 !~ /^[ \t]*$/) {
                    section_end = FNR
                }

                if (!active_line && $0 ~ active_pattern) {
                    active_line = FNR
                }

                if (!commented_line && $0 ~ commented_pattern) {
                    commented_line = FNR
                }
            }

            next
        }

        !initialised {
            target      = active_line ? active_line : commented_line
            initialised = 1
        }

        FNR == target {
            print key "=" value
            next
        }

        { print }

        FNR == section_end && !target && section_found {
            print key "=" value
        }

        END {
            if (!section_found) {
                print ""
                print "[" section "]"
                print key "=" value
            }
        }

    ' "$file" "$file" > "$temp_file"; then

        rm -f "$temp_file"
        warn "Could not prepare the update of $key in $file."
        return 1
    fi

    # "cat >" keeps owner and permissions of the original file.
    if ! cat "$temp_file" > "$file"; then
        rm -f "$temp_file"
        warn "Could not write $file."
        return 1
    fi

    rm -f "$temp_file"
    return 0
}


# ----------------------------------------------------------
# SSH PORTS
#
# Collected BEFORE the questions, for two reasons: the chosen
# RDP port must not collide with SSH, and the firewall is
# enabled early, so the SSH ports have to be known by then.
# ----------------------------------------------------------

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


# The port of the connection this script is running in.

if [[ -n "${SSH_CONNECTION:-}" ]]; then

    read -r _ _ _ SSH_CURRENT_PORT <<< "$SSH_CONNECTION"

    add_ssh_port "$SSH_CURRENT_PORT"

fi

# The effective sshd configuration.

if command -v sshd >/dev/null 2>&1; then

    SSHD_CONFIG="$(sshd -T 2>/dev/null || true)"

    while read -r KEY VALUE _; do

        if [[ "$KEY" == "port" ]]; then
            add_ssh_port "$VALUE"
        fi

    done <<< "$SSHD_CONFIG"

fi

# What sshd is actually listening on. This is the safety net:
# "sshd -T" fails on some configurations, and locking the
# running SSH connection out would leave the server
# unreachable.

if command -v ss >/dev/null 2>&1; then

    SSHD_LISTEN_PORTS="$(
        LC_ALL=C ss -tlnp 2>/dev/null | awk '
            NR > 1 && /"sshd"/ {
                address = $4
                sub(/.*:/, "", address)
                print address
            }' | sort -u
    )"

    while read -r LISTEN_PORT; do

        if [[ -n "$LISTEN_PORT" ]]; then
            add_ssh_port "$LISTEN_PORT"
        fi

    done <<< "$SSHD_LISTEN_PORTS"

fi

if (( ${#SSH_PORTS[@]} == 0 )); then
    add_ssh_port 22
fi


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
#
# The port is asked in a loop: a port that is already taken is
# a typo, not a reason to start the whole installation again.
# ----------------------------------------------------------

echo

while true; do

    read -rp \
        "RDP port [$DEFAULT_RDP_PORT]: " \
        RDP_PORT < /dev/tty

    RDP_PORT="${RDP_PORT:-$DEFAULT_RDP_PORT}"

    if ! [[ "$RDP_PORT" =~ ^[0-9]+$ ]] ||
       (( RDP_PORT < 1 || RDP_PORT > 65535 )); then

        echo "ERROR: Invalid port number."
        continue
    fi

    if (( RDP_PORT < MIN_UNPRIVILEGED_PORT )) &&
       (( RDP_PORT != DEFAULT_RDP_PORT )); then

        echo "ERROR: Ports below $MIN_UNPRIVILEGED_PORT are reserved for system services."
        continue
    fi

    # Ports that would collide with other common services.

    PORT_REJECTED=false

    for RESERVED in 80 443 3350 5900 9666; do

        if (( RDP_PORT == RESERVED )); then
            echo "ERROR: Port $RDP_PORT is used by another common service."
            PORT_REJECTED=true
        fi

    done

    # SSH is the way back in if RDP ever breaks. Taking its
    # port would cost both at once.

    for SSH_PORT in "${SSH_PORTS[@]}"; do

        if (( RDP_PORT == SSH_PORT )); then
            echo "ERROR: Port $RDP_PORT is the SSH port of this server."
            PORT_REJECTED=true
        fi

    done

    if [[ "$PORT_REJECTED" == true ]]; then
        continue
    fi

    # Anything else that is already listening. A port in use
    # would let the XRDP service fail to start much later, with
    # an error message that says nothing about the real cause.

    if command -v ss >/dev/null 2>&1; then

        PORT_LISTENER="$(listener_on_port "$RDP_PORT")"

        if [[ -n "$PORT_LISTENER" ]]; then

            if [[ "$PORT_LISTENER" == *xrdp* ]]; then

                echo "NOTE: XRDP already listens on port $RDP_PORT."

            else

                echo "ERROR: Port $RDP_PORT is already in use:"
                echo "  $PORT_LISTENER"
                continue

            fi

        fi

    fi

    break

done

if (( RDP_PORT == DEFAULT_RDP_PORT )); then
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

    MIN_PASSWORD_LENGTH="$MIN_PASSWORD_LENGTH_RESTRICTED"

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
    MIN_PASSWORD_LENGTH="$MIN_PASSWORD_LENGTH_PUBLIC"

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
# DNS RESOLVERS
#
# Some hosting providers ship name servers that throttle
# bursts of queries. A browser resolves 20-50 names while
# building a single page, so the throttling shows up as pages
# that load slowly or time out - while a single lookup on the
# command line still looks perfectly healthy.
#
# Not every network wants this, so it is a question.
# ----------------------------------------------------------

echo

read -rp \
    "Replace the name servers with $DNS_PRIMARY and $DNS_SECONDARY? [Y/n]: " \
    CHANGE_DNS < /dev/tty

CHANGE_DNS="${CHANGE_DNS:-Y}"

if [[ "$CHANGE_DNS" =~ ^[Yy]$ ]]; then

    CHANGE_DNS=true

    echo "NOTE: The current name servers are backed up and restored"
    echo "      automatically if name resolution stops working."

else

    CHANGE_DNS=false

    echo "NOTE: Keeping the name servers of this network."

fi


# ----------------------------------------------------------
# UPDATE POLICY
#
# The default Ubuntu behaviour installs security updates in the
# background, whenever its timer fires. On a machine that is
# being worked on, a service restarted at the wrong moment can
# tear down a running desktop session.
#
# The alternative offered here moves the work to boot time,
# which is the one moment when nothing is running yet.
# ----------------------------------------------------------

echo

read -rp \
    "Install system updates at boot instead of during work? [y/N]: " \
    BOOT_UPDATES < /dev/tty

BOOT_UPDATES="${BOOT_UPDATES:-N}"

if [[ "$BOOT_UPDATES" =~ ^[Yy]$ ]]; then

    BOOT_UPDATES=true

    echo "NOTE: Updates are installed while the server boots."
    echo "      RDP waits for them; SSH stays available throughout."
    echo "      Security updates keep arriving in the background,"
    echo "      but no service is restarted while you are working."

else

    BOOT_UPDATES=false

    echo "NOTE: Keeping the standard Ubuntu update behaviour."

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


# ==========================================================
# From here on the system is modified.
# ==========================================================


# ----------------------------------------------------------
# DNS RESOLVERS
#
# The addresses are replaced where netplan configures the
# link. Name servers defined there take precedence over
# anything in resolved.conf, and netplan MERGES lists from
# additional files instead of replacing them - so editing the
# existing file is the only reliable way.
# ----------------------------------------------------------

echo
echo "[1/14] Configuring DNS resolvers"

CLOUD_INIT_FILE="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
CLOUD_INIT_FILE_CREATED=false


# A real lookup, not a ping: this is exactly what breaks when a
# provider blocks foreign resolvers.

dns_resolves_names() {
    local host

    for host in archive.ubuntu.com security.ubuntu.com; do

        if timeout 10 getent hosts "$host" >/dev/null 2>&1; then
            return 0
        fi

    done

    return 1
}


restore_netplan_backup() {
    local backup="$1"
    local target="$2"

    cp -a "$backup" "$target" || return 1

    if netplan generate >/dev/null 2>&1; then
        netplan apply >/dev/null 2>&1 || true
        sleep 2
    fi

    if [[ "$CLOUD_INIT_FILE_CREATED" == true ]]; then
        rm -f "$CLOUD_INIT_FILE"
        CLOUD_INIT_FILE_CREATED=false
    fi

    return 0
}


if [[ "$CHANGE_DNS" == false ]]; then

    echo "Skipped on request."

else

    # "sed -n 1p" instead of "head -n1": a reader that closes the
    # pipe early kills grep with SIGPIPE, which "set -o pipefail"
    # would report as a failure.
    NETPLAN_FILE="$(grep -l 'nameservers' /etc/netplan/*.yaml 2>/dev/null | sed -n '1p' || true)"

    if [[ -z "$NETPLAN_FILE" ]]; then

        echo "No netplan file with name servers found - keeping current setup."

    else

        echo "Setting $DNS_PRIMARY and $DNS_SECONDARY in $NETPLAN_FILE"

        # Whether name resolution worked BEFORE anything was
        # touched. Without this, a server that arrived with broken
        # DNS would later be blamed on the new name servers.
        if dns_resolves_names; then
            DNS_WORKED_BEFORE=true
        else
            DNS_WORKED_BEFORE=false
            echo "NOTE: Name resolution is already not working on this server."
        fi

        DNS_STEP_OK=true

        NETPLAN_BACKUP="${NETPLAN_FILE}.backup_$(date +%Y%m%d_%H%M%S)"

        # No backup, no change: without a way back, editing the
        # file that carries the network configuration is reckless.
        if ! cp -a "$NETPLAN_FILE" "$NETPLAN_BACKUP"; then
            warn "Could not back up $NETPLAN_FILE - the name servers were left unchanged."
            DNS_STEP_OK=false
        fi

        if [[ "$DNS_STEP_OK" == true ]] &&
           ! python3 -c 'import yaml' 2>/dev/null; then

            if ! apt-get update ||
               ! apt-get install -y python3-yaml; then

                warn "Could not install python3-yaml - name servers were not changed."
                DNS_STEP_OK=false

            fi

        fi

        # Rewriting the YAML is safer than a text substitution:
        # the provider addresses differ between machines.
        if [[ "$DNS_STEP_OK" == true ]]; then

            if ! python3 - "$NETPLAN_FILE" "$DNS_PRIMARY" "$DNS_SECONDARY" <<'PYTHON'
import sys

import yaml

path, primary, secondary = sys.argv[1], sys.argv[2], sys.argv[3]

DEVICE_TYPES = ("ethernets", "bonds", "bridges", "vlans", "wifis")

with open(path) as handle:
    config = yaml.safe_load(handle) or {}

network = config.get("network")

if not isinstance(network, dict):
    sys.exit("no 'network' section in the netplan configuration")

changed = 0

for device_type in DEVICE_TYPES:

    devices = network.get(device_type)

    if not isinstance(devices, dict):
        continue

    for device in devices.values():

        if not isinstance(device, dict):
            continue

        nameservers = device.get("nameservers")

        if not isinstance(nameservers, dict):
            nameservers = {}
            device["nameservers"] = nameservers

        nameservers["addresses"] = [primary, secondary]
        changed += 1

if changed == 0:
    sys.exit("no network device found in the netplan configuration")

with open(path, "w") as handle:
    yaml.safe_dump(config, handle, default_flow_style=False, sort_keys=False)
PYTHON
            then

                warn "The netplan file could not be rewritten - keeping the original."

                if ! cp -a "$NETPLAN_BACKUP" "$NETPLAN_FILE"; then
                    warn "The original netplan file could not be restored from $NETPLAN_BACKUP."
                fi

                DNS_STEP_OK=false

            fi

        fi

        if [[ "$DNS_STEP_OK" == true ]]; then

            # netplan warns about world readable configuration files.
            if ! chmod 600 "$NETPLAN_FILE"; then
                warn "Could not tighten the permissions of $NETPLAN_FILE."
            fi

            # "netplan generate" only validates the files and writes the
            # backend configuration. It does not touch the running network,
            # so a broken file is caught before it can cut the connection.
            if ! netplan generate; then

                warn "netplan rejected the change - the backup was restored."
                restore_netplan_backup "$NETPLAN_BACKUP" "$NETPLAN_FILE" || true
                DNS_STEP_OK=false

            fi

        fi

        if [[ "$DNS_STEP_OK" == true ]]; then

            if ! netplan apply; then

                warn "netplan could not apply the new name servers - the backup was restored."
                restore_netplan_backup "$NETPLAN_BACKUP" "$NETPLAN_FILE" || true
                DNS_STEP_OK=false

            else

                sleep 2

            fi

        fi

        if [[ "$DNS_STEP_OK" == true ]]; then

            # Without this, cloud-init writes the provider's name servers
            # back into the file on the next boot.
            if [[ -d /etc/cloud/cloud.cfg.d && ! -f "$CLOUD_INIT_FILE" ]]; then

                echo 'network: {config: disabled}' > "$CLOUD_INIT_FILE"
                CLOUD_INIT_FILE_CREATED=true

            fi

            # The safety net. Some providers block foreign resolvers
            # completely; without this check the installation would
            # die at the next apt command, on a server that has no
            # working name resolution left.
            echo "Checking name resolution..."

            if dns_resolves_names; then

                echo "Name servers now in use:"
                LC_ALL=C resolvectl status 2>/dev/null \
                    | grep -i 'DNS Server' \
                    | sed 's/^/  /' || true

            else

                warn "No name resolution with $DNS_PRIMARY / $DNS_SECONDARY - the previous name servers were restored."

                restore_netplan_backup "$NETPLAN_BACKUP" "$NETPLAN_FILE" || true

                if dns_resolves_names; then

                    echo "Name resolution works again with the previous name servers."
                    echo "This network apparently blocks external resolvers."

                else

                    echo "ERROR: This server has no working name resolution." >&2

                    if [[ "$DNS_WORKED_BEFORE" == false ]]; then
                        echo "       It was already broken before this installer ran," >&2
                        echo "       so the cause is not the name server change." >&2
                    fi

                    echo "       The installation cannot continue." >&2
                    exit 1

                fi

            fi

        fi

    fi

fi


# ----------------------------------------------------------
# SYSTEM UPDATE
# ----------------------------------------------------------

echo
echo "[2/14] Updating system"

apt-get update

if ! apt-get upgrade -y; then
    warn "Not all packages could be upgraded. The installation continues."
fi


# ----------------------------------------------------------
# FIREWALL
#
# Deliberately BEFORE XRDP is installed. A freshly installed
# xrdp starts on port 3389 immediately, and on a server with
# no firewall that port would be open to the Internet for the
# rest of the installation.
# ----------------------------------------------------------

echo
echo "[3/14] Configuring UFW"

if ! command -v ufw >/dev/null 2>&1; then

    if ! apt-get install -y ufw; then
        echo "ERROR: UFW could not be installed." >&2
        echo "       Refusing to continue without a firewall." >&2
        exit 1
    fi

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
# Removes rules for the default port, for the configured port,
# and every rule this installer created earlier - the last one
# matters when a previous run used a different port, whose
# rule would otherwise stay open forever.
# ----------------------------------------------------------

UFW_ADDED_RULES="$(
    LC_ALL=C ufw show added 2>/dev/null || true
)"

while IFS= read -r UFW_LINE; do

    [[ "$UFW_LINE" == ufw\ * ]] || continue

    RULE="${UFW_LINE#ufw }"

    IS_RDP_RULE=false

    # Rules written by an earlier run carry this comment, no
    # matter which port they use.
    if [[ "$RULE" == *"comment 'XRDP'"* ]]; then
        IS_RDP_RULE=true
    fi

    # Remove optional comment.
    RULE="${RULE%% comment *}"

    for CHECK_PORT in "$DEFAULT_RDP_PORT" "$RDP_PORT"; do

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
# FIREWALL DEFAULTS AND RDP RULE
# ----------------------------------------------------------

ufw default deny incoming
ufw default allow outgoing

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
# INSTALL CORE PACKAGES
# ----------------------------------------------------------

echo
echo "[4/14] Installing XFCE, XRDP and dependencies"

# sudo is not in this list on purpose. Ubuntu 26.04 ships
# sudo-rs as the default provider; installing the package
# blindly would change a working setup for no reason.

if ! command -v sudo >/dev/null 2>&1; then

    if ! apt-get install -y sudo; then
        echo "ERROR: sudo could not be installed." >&2
        exit 1
    fi

fi

apt-get install -y \
    xfce4 \
    xfce4-goodies \
    xrdp \
    xorgxrdp \
    xserver-xorg-core \
    dbus-x11 \
    x11-xserver-utils \
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

    if ! apt-get install -y "$POLKIT_PKG"; then
        warn "The polkit package $POLKIT_PKG could not be installed."
    fi

else

    warn "No supported polkit package was found."

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
        warn "FUSE installation failed. AppImages may not start."
    fi

else

    warn "No FUSE 2 package found. AppImages may not start."

fi


# ----------------------------------------------------------
# XRDP CONFIGURATION
# ----------------------------------------------------------

echo
echo "[5/14] Configuring XRDP"

if getent group ssl-cert >/dev/null 2>&1; then

    if ! usermod -aG ssl-cert xrdp; then
        warn "Could not add the xrdp user to the ssl-cert group."
    fi

fi

XRDP_INI="/etc/xrdp/xrdp.ini"
SESMAN_INI="/etc/xrdp/sesman.ini"

if [[ -f "$XRDP_INI" && ! -f "${XRDP_INI}.orig" ]]; then
    cp -a "$XRDP_INI" "${XRDP_INI}.orig"
fi

if [[ -f "$SESMAN_INI" && ! -f "${SESMAN_INI}.orig" ]]; then
    cp -a "$SESMAN_INI" "${SESMAN_INI}.orig"
fi

# Listening port.

set_ini_key "$XRDP_INI" "Globals" "port" "$RDP_PORT" || true

# Fixed colour depth.
#
# XRDP creates a SEPARATE session per colour depth. Different
# clients negotiate different values, which silently produces
# several parallel sessions for the same user.
#
# Capping the value keeps all clients in one single session.

set_ini_key "$XRDP_INI" "Globals" "max_bpp" "24" || true


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
echo "[6/14] Configuring persistent sessions"

set_ini_key "$SESMAN_INI" "Sessions" "Policy" "Default" || true
set_ini_key "$SESMAN_INI" "Sessions" "KillDisconnected" "false" || true
set_ini_key "$SESMAN_INI" "Sessions" "DisconnectedTimeLimit" "0" || true
set_ini_key "$SESMAN_INI" "Sessions" "IdleTimeLimit" "0" || true

# A low limit surfaces stale sessions early instead of
# letting dozens of them pile up unnoticed.

set_ini_key "$SESMAN_INI" "Sessions" "MaxSessions" "3" || true

systemctl enable xrdp

systemctl restart xrdp-sesman
systemctl restart xrdp


# ----------------------------------------------------------
# CREATE / CONFIGURE USER
# ----------------------------------------------------------

echo
echo "[7/14] Configuring user '$USERNAME'"

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
echo "[8/14] Configuring XFCE session"

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
echo "[9/14] Configuring polkit for XRDP"

if command -v pkaction >/dev/null 2>&1; then

    POLKIT_OUTPUT="$(LC_ALL=C pkaction --version 2>/dev/null || true)"
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

    warn "pkaction was not found - the XRDP polkit configuration was skipped."

fi


# ----------------------------------------------------------
# FAIL2BAN
#
# Bans an IP after repeated failed logins. The port stays
# open for everyone else.
#
# Ubuntu ships a filter for SSH only, so the XRDP filter is
# created here - under its own name, so a future distribution
# filter called xrdp.conf cannot collide with it.
# ----------------------------------------------------------

echo
echo "[10/14] Configuring fail2ban"

cat > "$XRDP_FILTER" <<'EOF'
# Matches the AUTHFAIL line written by xrdp-sesman, e.g.
#
#   [20260101-12:00:00] [INFO ] AUTHFAIL: user=name ip=::ffff:203.0.113.10 time=1767265200
#
# The optional ::ffff: prefix is how an IPv4 address is
# represented inside an IPv6 field. It is matched but NOT
# captured: capturing it would put an unusable IPv6 address
# into the ban rule.
#
# The leading "[...]" blocks are optional and repeatable on
# purpose. fail2ban normally cuts the timestamp off before
# matching, which leaves "[INFO ] AUTHFAIL: ...", but if
# datepattern ever stops matching, the full line arrives here
# with both blocks. A pattern that only allows one of them
# would then match nothing at all - and a jail that matches
# nothing looks healthy while banning nobody.

[Definition]
failregex = ^(?:\s*\[[^\]]*\])*\s*AUTHFAIL:\s+user=\S*\s+ip=(?:::ffff:)?<HOST>\s+time=\d+\s*$
ignoreregex =
datepattern = ^\[%%Y%%m%%d-%%H:%%M:%%S\]
EOF

chmod 0644 "$XRDP_FILTER"


# The sshd jail must know the real SSH port. fail2ban bans an
# address per port: with the default "port = ssh" a ban only
# covers port 22, so on a server with a custom SSH port the
# jail looks healthy and blocks nobody.

SSH_PORT_LIST="$(IFS=,; echo "${SSH_PORTS[*]}")"

# Minimal Ubuntu images no longer install rsyslog, so
# /var/log/auth.log may not exist at all. fail2ban then finds
# no log file and quietly refuses to start the sshd jail.

if [[ -f /var/log/auth.log ]]; then
    SSHD_BACKEND="auto"
    SSHD_LOGPATH_LINE="logpath  = /var/log/auth.log"
else
    SSHD_BACKEND="systemd"
    SSHD_LOGPATH_LINE="# no auth.log on this system, reading the journal instead"
fi

# "polling" instead of "auto": xrdp writes to a plain file,
# and polling is the one backend that works on every system,
# with or without pyinotify.

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = $SSH_PORT_LIST
backend  = $SSHD_BACKEND
$SSHD_LOGPATH_LINE

[xrdp]
enabled  = true
port     = $RDP_PORT
filter   = xrdp-sesman
logpath  = $SESMAN_LOG
backend  = polling
maxretry = 5
bantime  = 1h
EOF

chmod 0644 /etc/fail2ban/jail.local

# fail2ban refuses to start a jail whose log file is missing.

if [[ ! -f "$SESMAN_LOG" ]]; then
    touch "$SESMAN_LOG"
    chmod 0640 "$SESMAN_LOG"
fi


# Proof that the filter really matches. A jail without a
# matching filter runs "green" and bans nobody, which is worse
# than no protection at all, because it is not noticed.

verify_xrdp_filter() {
    local sample_log
    local output

    if ! command -v fail2ban-regex >/dev/null 2>&1; then
        warn "fail2ban-regex not found - the XRDP filter could not be verified."
        return 1
    fi

    if ! sample_log="$(mktemp)"; then
        return 1
    fi

    # Two genuine AUTHFAIL lines: one with the ::ffff: prefix,
    # one without.
    cat > "$sample_log" <<'EOF'
[20260101-12:00:00] [INFO ] AUTHFAIL: user=testuser ip=::ffff:203.0.113.10 time=1767265200
[20260101-12:00:05] [INFO ] AUTHFAIL: user=testuser ip=198.51.100.23 time=1767265205
EOF

    output="$(fail2ban-regex "$sample_log" "$XRDP_FILTER" 2>&1 || true)"
    rm -f "$sample_log"

    if [[ "$output" != *"2 matched"* ]]; then
        warn "The XRDP fail2ban filter did not match the test lines - RDP brute force protection is probably not working."
        return 1
    fi

    echo "XRDP filter check: 2 of 2 test lines matched."

    # A test line only proves that the filter matches the format
    # this installer knows. If the server has already logged real
    # failed logins, check against those as well - they are the
    # only evidence that the format has not changed.
    if grep -q 'AUTHFAIL:' "$SESMAN_LOG" 2>/dev/null; then

        output="$(fail2ban-regex "$SESMAN_LOG" "$XRDP_FILTER" 2>&1 || true)"

        if [[ "$output" == *" 0 matched"* ]]; then
            warn "The XRDP filter matches no line of the existing $SESMAN_LOG - the log format may have changed."
            return 1
        fi

        echo "XRDP filter check: existing log entries are matched as well."

    fi

    return 0
}

verify_xrdp_filter || true

if ! systemctl enable fail2ban >/dev/null 2>&1; then
    warn "fail2ban could not be enabled at boot."
fi

if ! systemctl restart fail2ban; then
    warn "fail2ban did not start - SSH and RDP are not protected against brute force."
fi


# ----------------------------------------------------------
# BROWSERS
# ----------------------------------------------------------

echo
echo "[11/14] Installing browsers"


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

            echo "Initial Chrome installation failed, attempting dependency repair..."

            apt-get -f install -y || true

            if ! apt-get install -y "$CHROME_DEB"; then
                warn "Google Chrome could not be installed."
            fi

        fi

    else

        warn "Failed to download Google Chrome."

    fi

    rm -f "$CHROME_DEB"

else

    echo "Google Chrome is unavailable for architecture '$ARCH'."
    echo "Trying Chromium instead..."

    if apt-cache show chromium-browser >/dev/null 2>&1; then

        if ! apt-get install -y chromium-browser; then
            warn "Chromium installation failed."
        fi

    elif apt-cache show chromium >/dev/null 2>&1; then

        if ! apt-get install -y chromium; then
            warn "Chromium installation failed."
        fi

    else

        warn "Chromium package was not found."

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

MOZILLA_KEYRING="/etc/apt/keyrings/packages.mozilla.org.asc"
MOZILLA_KEY_TEMP="/tmp/packages.mozilla.org.asc"

install -d -m 0755 /etc/apt/keyrings

# Download first, install second. Redirecting wget straight
# into the keyring would leave an empty file behind if the
# download fails.
if wget -qO "$MOZILLA_KEY_TEMP" "https://packages.mozilla.org/apt/repo-signing-key.gpg"; then

    # Remove the Snap build and the wrapper package only once
    # the replacement is known to be available.
    if command -v snap >/dev/null 2>&1; then
        snap remove --purge firefox >/dev/null 2>&1 || true
    fi

    apt-get purge -y firefox >/dev/null 2>&1 || true

    install -m 0644 "$MOZILLA_KEY_TEMP" "$MOZILLA_KEYRING"

    echo "deb [signed-by=$MOZILLA_KEYRING] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list

    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
        > /etc/apt/preferences.d/mozilla

    if ! apt-get update; then
        warn "Could not read Mozilla's APT repository."
    fi

    if ! apt-get install -y firefox; then
        warn "Firefox installation failed."
    fi

else

    warn "Could not download Mozilla's signing key - Firefox was skipped."

fi

rm -f "$MOZILLA_KEY_TEMP"


# ----------------------------------------------------------
# JDOWNLOADER (OPTIONAL)
# ----------------------------------------------------------

echo
echo "[12/14] Installing optional components"

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
        warn "Could not install $JAVA_PKG - JDownloader was skipped."
        JD_MODE="none"
    fi

fi

if [[ "$JD_MODE" != "none" ]]; then

    mkdir -p "$JD_DIR"

    JD_JAR="$JD_DIR/JDownloader.jar"

    # https, not http: this file is started as a user with sudo
    # rights, so an unencrypted download would be an invitation
    # to replace it on the way.
    if wget -qO "$JD_JAR" "https://installer.jdownloader.org/JDownloader.jar"; then

        JD_JAR_SIZE="$(stat -c '%s' "$JD_JAR" 2>/dev/null || echo 0)"

        if (( JD_JAR_SIZE < MIN_JAR_SIZE_BYTES )); then

            warn "The downloaded JDownloader file is too small ($JD_JAR_SIZE bytes) - JDownloader was skipped."
            rm -f "$JD_JAR"
            JD_MODE="none"

        fi

    else

        warn "Failed to download JDownloader."
        JD_MODE="none"

    fi

fi

if [[ "$JD_MODE" != "none" ]]; then

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

        if ! systemctl enable jdownloader; then
            warn "The JDownloader service could not be enabled at boot."
        fi

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

fi


# ----------------------------------------------------------
# SESSION RESET HELPER
#
# A stuck window manager can leave a session that refuses
# new connections. This helper clears it from SSH.
#
# Killing the processes is not enough: the X server leaves a
# socket and a lock file behind, and a new session on the same
# display number then fails to start. Those leftovers are
# removed here - but only for displays where no X server is
# running any more, so a display that belongs to another
# service is never touched.
# ----------------------------------------------------------

cat > /usr/local/bin/xrdp-session-reset <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\$EUID" -ne 0 ]]; then
    echo "Please run as root." >&2
    exit 1
fi

echo "Terminating the RDP session processes of user '$USERNAME'..."

# Processes that must SURVIVE: the Sunshine setup from sunshine.sh
# (its own screen, desktop and stream) and the user's own systemd
# instance, which is where PipeWire runs.
#
# systemd keeps every process of a unit in that unit's own cgroup, so
# the list below is exact - no guessing by process name. Sub-cgroups
# are included, which is how the services under user@<UID>.service are
# found. If none of these paths exist - no Sunshine, or an older
# cgroup layout - the list stays empty and everything is terminated,
# exactly as before.
declare -A SPARED_PIDS=()

collect_pids() {
    local procs_file="\$1"
    local pid

    [[ -r "\$procs_file" ]] || return 0

    while read -r pid; do
        if [[ -n "\$pid" ]]; then
            SPARED_PIDS["\$pid"]=1
        fi
    done < "\$procs_file"
}

TARGET_UID="\$(id -u '$USERNAME')"

for CGROUP_BASE in \\
    /sys/fs/cgroup/system.slice/sunshine-xorg.service \\
    /sys/fs/cgroup/system.slice/sunshine-desktop.service \\
    /sys/fs/cgroup/system.slice/sunshine-stream.service \\
    "/sys/fs/cgroup/user.slice/user-\${TARGET_UID}.slice/user@\${TARGET_UID}.service"
do

    [[ -d "\$CGROUP_BASE" ]] || continue

    while read -r PROCS_FILE; do
        collect_pids "\$PROCS_FILE"
    done < <(find "\$CGROUP_BASE" -name cgroup.procs 2>/dev/null)

done

if (( \${#SPARED_PIDS[@]} > 0 )); then
    echo "Sparing \${#SPARED_PIDS[@]} process(es) of the Sunshine setup."
fi

# Two rounds: first the polite request, then the hammer for whatever
# ignored it.
for SIGNAL in TERM KILL; do

    while read -r PID; do

        [[ -n "\$PID" ]] || continue

        if [[ -n "\${SPARED_PIDS[\$PID]:-}" ]]; then
            continue
        fi

        kill "-\$SIGNAL" "\$PID" 2>/dev/null || true

    done < <(pgrep -u "$USERNAME" || true)

    sleep 2

done

echo "Removing orphaned X server sockets..."

for SOCKET in /tmp/.X11-unix/X*; do

    [[ -e "\$SOCKET" ]] || continue

    DISPLAY_NUMBER="\${SOCKET##*/X}"

    [[ "\$DISPLAY_NUMBER" =~ ^[0-9]+\$ ]] || continue

    # Still in use by a running X server? Then leave it alone.
    #
    # "> /dev/null" instead of "grep -q": with -q, grep exits at the
    # first match and can kill pgrep with SIGPIPE, which under
    # "set -o pipefail" would turn a match into a false negative - and
    # a socket that is still in use would be deleted.
    if pgrep -af 'X(org|vfb|vnc)' 2>/dev/null |
       grep -E "(^| ):\${DISPLAY_NUMBER}( |\\\$)" > /dev/null; then
        continue
    fi

    rm -f "\$SOCKET" "/tmp/.X\${DISPLAY_NUMBER}-lock"

done

systemctl restart xrdp-sesman
systemctl restart xrdp

echo "Done. Reconnect using <SERVER_IP>:$RDP_PORT"

if [[ -x /usr/local/bin/sunshine-session-reset ]]; then
    echo
    echo "The Sunshine desktop was left running on purpose."
    echo "To reset that one as well:  sunshine-session-reset"
fi
EOF

chmod 0755 /usr/local/bin/xrdp-session-reset


# ----------------------------------------------------------
# UPDATE POLICY
#
# Moves the update work to boot time, the one moment when no
# session is running and a service restart costs nothing.
#
# Three parts:
#   - a service that updates the system while it boots
#   - needrestart only lists services during normal operation
#   - unattended-upgrades leaves XRDP alone
# ----------------------------------------------------------

echo
echo "[13/14] Configuring update policy"

if [[ "$BOOT_UPDATES" == false ]]; then

    echo "Keeping the standard Ubuntu update behaviour."

else

    cat > "$BOOT_UPDATE_SCRIPT" <<'BOOT_UPDATE_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Installs pending updates once, while the system boots.
#
# Started by xrdp-boot-update.service, which XRDP waits for.
# SSH deliberately does not wait: if this ever hangs, the server
# still has to be reachable.
#
# Nothing is ever rebooted here. The reboot is always the user's.

readonly LOG_FILE="/var/log/xrdp-boot-update.log"
readonly MAX_LOG_BYTES=1048576
readonly DNS_WAIT_SECONDS=90
readonly DNS_PROBE_HOST="archive.ubuntu.com"

# At boot nothing is in use yet, so this is the right moment to
# let services restart. While the system is running, needrestart
# is configured to only list them.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# Keep the log from growing without bound.
if [[ -f "$LOG_FILE" ]] &&
   (( $(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0) > MAX_LOG_BYTES )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.old"
fi

log "===== boot update started ====="

# network-online.target can be reached before name resolution
# actually answers.
waited=0

while ! getent hosts "$DNS_PROBE_HOST" >/dev/null 2>&1; do

    if (( waited >= DNS_WAIT_SECONDS )); then
        log "no name resolution after ${DNS_WAIT_SECONDS}s - nothing was updated"
        exit 0
    fi

    sleep 5
    waited=$(( waited + 5 ))

done

if ! apt-get update >> "$LOG_FILE" 2>&1; then
    log "apt-get update failed - nothing was updated"
    exit 0
fi

# "upgrade", not "full-upgrade": this never removes a package.
#
# Retries and timeouts keep a slow mirror from holding the
# desktop back for the full service timeout.
if apt-get -y \
        -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 \
        upgrade >> "$LOG_FILE" 2>&1; then

    log "upgrade finished"

else

    log "upgrade FAILED - see the apt output above"

fi

# A new kernel only takes effect on the NEXT boot.
if [[ -f /var/run/reboot-required ]]; then
    log "a new kernel was installed - it becomes active on the next reboot"
fi

log "===== boot update finished ====="
BOOT_UPDATE_EOF

    chmod 0755 "$BOOT_UPDATE_SCRIPT"

    cat > "$BOOT_UPDATE_SERVICE" <<EOF
[Unit]
Description=Install pending system updates at boot
After=network-online.target
Wants=network-online.target

# XRDP waits for the update to finish, so an upgrade can never
# pull the desktop out from under a session.
#
# SSH is deliberately NOT listed here: if an update ever hangs,
# the machine has to stay reachable.
Before=xrdp.service xrdp-sesman.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BOOT_UPDATE_SCRIPT

# An update that hangs must not block the desktop forever.
# Generous on purpose: aborting dpkg halfway is worse than waiting.
TimeoutStartSec=30min

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "$BOOT_UPDATE_SERVICE"

    # needrestart asks which services to restart after an upgrade,
    # and restarts them. While somebody is working, that is exactly
    # what must not happen.
    if [[ -d /etc/needrestart ]]; then

        mkdir -p /etc/needrestart/conf.d

        cat > /etc/needrestart/conf.d/99-xrdp-installer.conf <<'EOF'
# Installed by the XRDP + XFCE installer.
#
# Only LIST outdated services while the system is running - a
# restart at the wrong moment tears down a live desktop session.
# xrdp-boot-update restarts them at boot instead.

$nrconf{restart} = 'l';
EOF

        chmod 0644 /etc/needrestart/conf.d/99-xrdp-installer.conf

    fi

    # Security updates keep arriving in the background, but XRDP
    # itself is left alone: upgrading it restarts the service and
    # disconnects a running desktop.
    cat > /etc/apt/apt.conf.d/52-xrdp-unattended-upgrades <<'EOF'
// Installed by the XRDP + XFCE installer.
//
// Security updates keep being installed in the background, but
// XRDP is excluded: upgrading it restarts the service and would
// disconnect a running desktop. It is upgraded at boot instead.

Unattended-Upgrade::Package-Blacklist {
    "xrdp";
    "xorgxrdp";
};

// Never reboot on its own. The reboot is always the user's.
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    chmod 0644 /etc/apt/apt.conf.d/52-xrdp-unattended-upgrades

    systemctl daemon-reload

    if systemctl enable xrdp-boot-update.service >/dev/null 2>&1; then
        echo "Updates will be installed at boot, before RDP becomes available."
        echo "Log: $BOOT_UPDATE_LOG"
    else
        warn "The boot update service could not be enabled."
    fi

fi


# ----------------------------------------------------------
# VERIFY
# ----------------------------------------------------------

echo
echo "[14/14] Verifying installation"

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

    # A running service says nothing about the jails. Both of
    # them have to be there, or the protection is imaginary.
    #
    # fail2ban needs a moment to read its configuration, so the
    # check waits instead of asking once and giving up.

    for JAIL in sshd xrdp; do

        JAIL_OK=false

        for _ in 1 2 3 4 5 6 7 8 9 10; do

            if fail2ban-client status "$JAIL" >/dev/null 2>&1; then
                JAIL_OK=true
                break
            fi

            sleep 1

        done

        if [[ "$JAIL_OK" == true ]]; then
            echo "  jail $JAIL: active"
        else
            echo "  jail $JAIL: NOT ACTIVE"
            warn "The fail2ban jail '$JAIL' is not active - brute force protection is incomplete."
        fi

    done

else

    echo "fail2ban:     WARNING (not running)"
    warn "fail2ban is not running."

fi


if [[ "$BOOT_UPDATES" == true ]]; then

    if systemctl is-enabled --quiet xrdp-boot-update.service 2>/dev/null; then
        echo "Boot updates: enabled"
    else
        echo "Boot updates: NOT ENABLED"
        warn "The boot update service is not enabled - updates will not run at boot."
    fi

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
        warn "Nothing is listening on port $RDP_PORT yet."
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

if [[ "$BOOT_UPDATES" == true ]]; then

    echo
    echo " Updates"
    echo
    echo " The system updates itself while it boots, before RDP"
    echo " becomes available. Nothing is upgraded or restarted while"
    echo " you are working. SSH is reachable during the update."
    echo
    echo " What happened last time:"
    echo "   tail -n 20 $BOOT_UPDATE_LOG"
    echo
    echo " Update now, without rebooting:"
    echo "   $BOOT_UPDATE_SCRIPT"
    echo
    echo " Security updates still arrive in the background, but no"
    echo " service is restarted and XRDP itself is left alone."
    echo
    echo " A new kernel only takes effect after the NEXT reboot."

fi

if [[ "$JD_MODE" == "service" ]]; then

    echo
    echo " JDownloader (headless service)"
    echo
    echo " First run is interactive. As root, run:"
    echo "   sudo -u $USERNAME java -Djava.awt.headless=true -jar $JD_DIR/JDownloader.jar"
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

if (( ${#WARNINGS[@]} > 0 )); then

    echo
    echo " --------------------------------------------------"
    echo " ${#WARNINGS[@]} step(s) did not complete:"
    echo

    for WARNING in "${WARNINGS[@]}"; do
        echo "   - $WARNING"
    done

    echo
    echo " The desktop itself is installed and working."

fi

echo
echo " Recommended: reboot before the first RDP login."
echo
echo "=================================================="
