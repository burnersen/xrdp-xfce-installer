#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# SSH port change for an XRDP + XFCE server
#
# Ubuntu 20.04 and newer
#
# Optional companion script for install.sh.
#
# Moves SSH to a port of your choice - without ever closing
# the door you are standing in.
#
#
# HOW IT WORKS
#
#   Phase 1  sshd listens on the OLD and the NEW port at the
#            same time. The firewall opens the new port and
#            fail2ban learns about it. Nothing is taken away.
#
#   Phase 2  You open a SECOND terminal and log in on the new
#            port. This script watches for that login and
#            refuses to continue until it has really seen it.
#
#   Phase 3  Only after your confirmation the old port is
#            removed - from sshd, from the firewall and from
#            fail2ban.
#
# If the connection this script runs in dies between phase 1
# and phase 3, a systemd timer puts everything back within a
# few minutes. The server cannot lock you out while nobody is
# watching it.
#
#
# WHY THIS IS NOT "sed -i s/22/2222/ sshd_config"
#
# Ubuntu 22.10 and newer start sshd through SOCKET ACTIVATION.
# The listening port then comes from the systemd unit
# ssh.socket - NOT from sshd_config. Editing only sshd_config
# on such a system changes nothing at all, and closing port 22
# in the firewall afterwards locks you out.
#
# Ubuntu ships a generator for this:
#
#   /usr/lib/systemd/system-generators/sshd-socket-generator
#
# It reads Port (and ListenAddress) out of sshd_config and
# writes the matching ListenStream= lines for ssh.socket. It
# runs on "systemctl daemon-reload". Where that generator
# exists, setting Port and reloading is the supported way.
# Where it does not, this script writes the ssh.socket
# drop-in itself.
#
# Whatever the mechanism, the result is VERIFIED with "ss"
# afterwards. A port that is not really listening is rolled
# back instead of believed.
#
#
# WHAT ELSE HAS TO FOLLOW THE PORT
#
#   ufw        a new port nobody may reach is not a new port
#   fail2ban   its sshd jail bans PER PORT. Left at 22, the
#              jail keeps running and stops banning anything
#   cloud      firewalls at the provider (Hetzner, AWS, ...)
#              are invisible from inside the server. This
#              script asks you about them, it cannot check
#              them
#
# Safe to run more than once.
# ==========================================================

readonly SCRIPT_VERSION="1.0.0"

# Same location as install.sh, german.sh and sunshine.sh use.
readonly BACKUP_DIR="/root/setup-backup"

readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
readonly SSHD_DROPIN="$SSHD_DROPIN_DIR/10-xrdp-installer-ssh-port.conf"

readonly SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"
readonly SOCKET_DROPIN="$SOCKET_DROPIN_DIR/10-xrdp-installer-ssh-port.conf"
readonly SOCKET_GENERATOR="/usr/lib/systemd/system-generators/sshd-socket-generator"

# fail2ban reads, in this order:
#   jail.conf, jail.d/*.conf, jail.local, jail.d/*.local
# install.sh writes jail.local, so only a *.local file inside
# jail.d/ is read after it and actually wins.
readonly F2B_DROPIN="/etc/fail2ban/jail.d/99-xrdp-ssh-port.local"

readonly STATE_DIR="/var/lib/xrdp-ssh-port"
readonly STATE_FILE="$STATE_DIR/pending"

readonly INSTALLED_COPY="/usr/local/sbin/xrdp-ssh-port"
readonly ROLLBACK_UNIT="xrdp-ssh-port-rollback"

readonly MOTD_HINT="/etc/update-motd.d/99-xrdp-ssh-port"

readonly DEFAULT_SSH_PORT=22
readonly MIN_UNPRIVILEGED_PORT=1024

# How long phase 1 may stand before the timer undoes it.
readonly ROLLBACK_MINUTES=15

# How long to wait for a port to actually appear in "ss".
readonly LISTEN_TIMEOUT=15

# Ports other parts of this project, or the system itself,
# are using. Same list as install.sh, plus Sunshine.
readonly RESERVED_PORTS="80 443 3350 5900 9666 47984 47989 48010"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly TIMESTAMP


declare -a WARNINGS=()

warn() {
    echo "WARNING: $*" >&2
    WARNINGS+=("$*")
}


on_error() {
    local exit_code=$?

    echo >&2
    echo "==================================================" >&2
    echo " ERROR: ssh-port.sh failed" >&2
    echo " Line:    $1" >&2
    echo " Command: $2" >&2
    echo " Exit:    $exit_code" >&2
    echo >&2

    if [[ -f "$STATE_FILE" ]]; then
        echo " A port change is STILL IN PROGRESS." >&2
        echo " Both ports are open, and the timer will put" >&2
        echo " everything back on its own." >&2
        echo >&2
        echo " To undo it right now:" >&2
        echo "   $INSTALLED_COPY --rollback" >&2
    else
        echo " Nothing was left half done." >&2
        echo " Backups are in $BACKUP_DIR" >&2
    fi

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

    [[ -f "$path" ]] || return 0

    mkdir -p "$BACKUP_DIR"
    cp -a "$path" "$BACKUP_DIR/$(basename "$path").$TIMESTAMP"
    echo "Backup: $BACKUP_DIR/$(basename "$path").$TIMESTAMP"
}


# "sshd -t" and "sshd -T" both abort with exit code 255 when
# /run/sshd is missing - and on a socket activated server that
# has not seen a single SSH connection since boot, it IS
# missing, because ssh.service creates it and ssh.service has
# not run yet.
#
# Without this, every config check below would fail for a
# reason that has nothing to do with the config.
ensure_run_sshd() {
    [[ -d /run/sshd ]] && return 0

    mkdir -p /run/sshd
    chmod 0755 /run/sshd
}


sshd_binary() {
    if [[ -x /usr/sbin/sshd ]]; then
        echo /usr/sbin/sshd
    else
        command -v sshd 2>/dev/null || echo /usr/sbin/sshd
    fi
}


# The effective sshd configuration, Include files and all.
sshd_effective_config() {
    ensure_run_sshd
    "$(sshd_binary)" -T 2>/dev/null || true
}


# Every port sshd is configured to listen on.
#
# "Port" is one of the few sshd keywords that ADD UP instead of
# overriding each other - several Port lines mean several
# ports. That is exactly what phase 1 relies on.
sshd_configured_ports() {
    sshd_effective_config | awk '$1 == "port" { print $2 }' | sort -un
}


# Is anything listening on this TCP port?
#
# This is the only answer that counts. sshd_config can say
# anything; ss says what the kernel actually does.
#
# On a socket activated system the listener may belong to
# systemd rather than to sshd - which is fine, a connection to
# it starts sshd. Who holds the socket does not matter here,
# only that the port answers.
port_is_listening() {
    local port="$1"
    local output

    output="$(ss -Htnl "( sport = :$port )" 2>/dev/null || true)"

    [[ -n "$output" ]]
}


# Waits for a port to show up, instead of asking once. systemd
# needs a moment between "restart" and a bound socket.
wait_for_listener() {
    local port="$1"
    local seconds="$2"
    local waited=0

    while (( waited < seconds )); do

        if port_is_listening "$port"; then
            return 0
        fi

        sleep 1
        waited=$(( waited + 1 ))

    done

    return 1
}


# Which process currently holds a port - for error messages
# that say something.
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


# The peers of the ESTABLISHED connections on a port, loopback
# left out. This is the proof that somebody really got in on
# the new port - not that the port merely answers.
#
# Without "-p" the peer address is always the last column, so
# picking NF survives the column shuffling that the state
# filter causes.
peers_on_port() {
    local port="$1"

    ss -Htn state established "( sport = :$port )" 2>/dev/null |
        awk '{ print $NF }' |
        sed 's/:[0-9]*$//; s/^\[//; s/\]$//' |
        grep -v -E '^(127\.|::1$)' |
        sort -u || true
}


# ----------------------------------------------------------
# SSH SERVICE MECHANICS
# ----------------------------------------------------------

systemd_is_running() {
    [[ -d /run/systemd/system ]]
}


# Ubuntu 22.10 and newer: sshd is started by ssh.socket, and
# the listening port lives in that unit, not in sshd_config.
socket_activated() {
    local state

    systemd_is_running || return 1

    state="$(systemctl is-enabled ssh.socket 2>/dev/null || true)"

    if [[ "$state" == "enabled" || "$state" == "enabled-runtime" ]]; then
        return 0
    fi

    systemctl is-active --quiet ssh.socket 2>/dev/null
}


ssh_service_unit() {
    if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        echo "ssh.service"
    else
        echo "sshd.service"
    fi
}


sshd_config_is_valid() {
    ensure_run_sshd
    "$(sshd_binary)" -t 2>&1
}


# ----------------------------------------------------------
# WRITING THE PORT
# ----------------------------------------------------------

# Marker on every line this script comments out, so the change
# can be undone without digging through backups.
readonly DISABLED_MARKER="# disabled by ssh-port.sh"


# Every sshd config file that could carry a Port line.
sshd_config_files() {
    local file

    echo "$SSHD_CONFIG"

    for file in "$SSHD_DROPIN_DIR"/*.conf; do

        [[ -f "$file" ]] || continue
        [[ "$file" == "$SSHD_DROPIN" ]] && continue

        echo "$file"

    done
}


# A Port line somewhere else would ADD ITSELF to ours - and
# phase 3 would then remove port 22 from our file while another
# file happily keeps it open. cloud-init writes such files.
#
# They are commented out, not deleted, and carry a marker so
# --revert can bring them back.
neutralise_foreign_port_lines() {
    local file
    local found=false

    while read -r file; do

        grep -qE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$file" || continue

        if [[ "$found" == false ]]; then
            echo "Other files also set a Port. Commenting those lines out:"
            found=true
        fi

        echo "  $file"
        grep -nE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$file" | sed 's/^/      /'

        backup_file "$file"

        sed -i -E \
            "s|^([[:space:]]*Port[[:space:]]+[0-9]+.*)$|#\\1  $DISABLED_MARKER|" \
            "$file"

    done < <(sshd_config_files)
}


restore_foreign_port_lines() {
    local file

    while read -r file; do

        grep -qF "$DISABLED_MARKER" "$file" || continue

        sed -i -E \
            "s|^#(.*)  $DISABLED_MARKER$|\\1|" \
            "$file"

        echo "Restored the Port line in $file"

    done < <(sshd_config_files)
}


# A ListenAddress that carries its OWN port beats Port
# completely, and the socket generator then produces nothing
# at all - the socket keeps its built in port 22 while
# sshd_config claims something else.
#
# Verified on Ubuntu 24.04:
#   Port 2222 + ListenAddress 0.0.0.0:22
#     -> "No custom listen addresses configured"
#   Port 2222 + ListenAddress 10.0.0.5     (no port)
#     -> ListenStream=10.0.0.5:2222        (follows along, fine)
#
# So only an explicit port is a problem.
listenaddress_with_port() {
    local file

    while read -r file; do

        grep -hE '^[[:space:]]*ListenAddress[[:space:]]+' "$file" 2>/dev/null |
            grep -E ':[0-9]+[[:space:]]*$' || true

    done < <(sshd_config_files)
}


# The one file this script owns.
write_sshd_dropin() {
    local port

    mkdir -p "$SSHD_DROPIN_DIR"
    chmod 0755 "$SSHD_DROPIN_DIR"

    {
        echo "# Written by ssh-port.sh $SCRIPT_VERSION on $(date '+%Y-%m-%d %H:%M:%S')"
        echo "#"
        echo "# Several Port lines mean several ports - sshd adds them up."
        echo "# Remove this file to go back to the Ubuntu default (port 22)."
        echo

        for port in "$@"; do
            echo "Port $port"
        done

    } > "$SSHD_DROPIN"

    chmod 0644 "$SSHD_DROPIN"
}


# Only needed where Ubuntu has socket activation but NO
# generator to translate sshd_config into ListenStream lines.
# Where the generator exists it does this itself on
# "systemctl daemon-reload", and a second drop-in would only
# be one more place to forget.
write_socket_dropin() {
    local port

    mkdir -p "$SOCKET_DROPIN_DIR"

    {
        echo "# Written by ssh-port.sh $SCRIPT_VERSION on $(date '+%Y-%m-%d %H:%M:%S')"
        echo "#"
        echo "# This system starts sshd through ssh.socket, and has no"
        echo "# sshd-socket-generator to derive the ports from sshd_config."
        echo
        echo "[Socket]"
        echo "# The empty value clears the built in ListenStream=0.0.0.0:22."
        echo "ListenStream="

        for port in "$@"; do
            echo "ListenStream=0.0.0.0:$port"
            echo "ListenStream=[::]:$port"
        done

    } > "$SOCKET_DROPIN"

    chmod 0644 "$SOCKET_DROPIN"
}


remove_socket_dropin() {
    [[ -f "$SOCKET_DROPIN" ]] || return 0

    rm -f "$SOCKET_DROPIN"
    rmdir --ignore-fail-on-non-empty "$SOCKET_DROPIN_DIR" 2>/dev/null || true
}


# Hands the new configuration to the running sshd.
#
# Socket activated: the ports live in ssh.socket, so the socket
# is restarted. ssh.service keeps the OLD listening socket it
# once inherited until it is restarted too - that is why it is
# restarted as well. Ubuntu's ssh.service uses KillMode=process,
# so the SSH sessions that are already open survive this.
#
# Classic: "reload" runs sshd -t and sends SIGHUP, which makes
# sshd re-exec and re-bind. Open sessions are separate
# processes and are not affected.
reload_ssh() {
    local unit

    unit="$(ssh_service_unit)"

    if ! systemd_is_running; then
        warn "systemd is not running - the SSH service was not reloaded."
        return 1
    fi

    if socket_activated; then

        systemctl daemon-reload || return 1

        systemctl restart ssh.socket || return 1

        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            systemctl restart "$unit" || true
        fi

        return 0

    fi

    if systemctl reload "$unit" 2>/dev/null; then
        return 0
    fi

    systemctl restart "$unit"
}


# Writes the ports, checks them, reloads sshd - and then asks
# the kernel whether any of it actually happened.
apply_ssh_ports() {
    local -a ports=("$@")
    local port
    local test_output

    write_sshd_dropin "${ports[@]}"

    if ! test_output="$(sshd_config_is_valid)"; then
        echo "ERROR: sshd rejected the configuration:" >&2
        echo "$test_output" | sed 's/^/  /' >&2
        return 1
    fi

    if socket_activated; then

        if [[ -x "$SOCKET_GENERATOR" ]]; then
            # The generator derives ListenStream from sshd_config.
            # A drop-in of ours next to it would be a second,
            # competing source of truth.
            remove_socket_dropin
        else
            write_socket_dropin "${ports[@]}"
        fi

    fi

    reload_ssh || return 1

    for port in "${ports[@]}"; do

        if ! wait_for_listener "$port" "$LISTEN_TIMEOUT"; then
            echo "ERROR: nothing is listening on port $port after the reload." >&2
            return 1
        fi

        echo "  port $port: listening"

    done

    return 0
}


assert_not_listening() {
    local port="$1"
    local waited=0

    # Closing takes a moment too.
    while (( waited < 10 )); do

        port_is_listening "$port" || return 0

        sleep 1
        waited=$(( waited + 1 ))

    done

    return 1
}


# ----------------------------------------------------------
# FIREWALL
# ----------------------------------------------------------

ufw_available() {
    command -v ufw >/dev/null 2>&1
}


ufw_is_active() {
    local output

    ufw_available || return 1

    # Captured instead of piped into grep: a reader that closes
    # the pipe early kills ufw with SIGPIPE, which "pipefail"
    # would report as a failure.
    output="$(LC_ALL=C ufw status 2>/dev/null || true)"

    [[ "$output" == *"Status: active"* ]]
}


ufw_allow_ssh_port() {
    local port="$1"

    ufw_available || return 0

    if ! ufw allow "${port}/tcp" comment "SSH" >/dev/null; then
        warn "ufw refused to open port $port."
        return 1
    fi

    echo "  ufw: port $port open"
}


# Removes every rule that opens a given SSH port, including
# the "OpenSSH" application profile, which is port 22 under a
# name.
ufw_remove_ssh_port() {
    local port="$1"
    local line
    local rule
    local is_match
    local -a rule_args
    local added

    ufw_available || return 0

    added="$(LC_ALL=C ufw show added 2>/dev/null || true)"

    while IFS= read -r line; do

        [[ "$line" == ufw\ * ]] || continue

        rule="${line#ufw }"
        is_match=false

        # ufw prints the profile rule as: allow OpenSSH
        if [[ "$port" == "$DEFAULT_SSH_PORT" ]] &&
           [[ "$rule" =~ (^|[[:space:]])\'?OpenSSH\'?([[:space:]]|$) ]]; then
            is_match=true
        fi

        rule="${rule%% comment *}"

        # allow 22   /   allow 22/tcp   /   limit 22/tcp
        if [[ "$rule" =~ ^(allow|deny|reject|limit)[[:space:]]+${port}(/tcp)?([[:space:]]|$) ]]; then
            is_match=true
        fi

        # allow from 203.0.113.10 to any port 22 proto tcp
        if [[ "$rule" =~ to[[:space:]]+any[[:space:]]+port[[:space:]]+${port}([[:space:]]|$) ]]; then
            is_match=true
        fi

        [[ "$is_match" == true ]] || continue

        echo "  ufw: removing  $rule"

        read -r -a rule_args <<< "$rule"

        if ! ufw delete "${rule_args[@]}" >/dev/null; then
            warn "ufw could not remove the rule: $rule"
        fi

    done <<< "$added"
}


# ----------------------------------------------------------
# FAIL2BAN
#
# The sshd jail bans an address ON A PORT. Ubuntu 24.04 uses
# the nftables action, whose rule literally contains
# "dport { 22 }". A jail left pointing at 22 while sshd has
# moved keeps running, reports itself as healthy, and bans
# nobody.
# ----------------------------------------------------------

fail2ban_available() {
    command -v fail2ban-client >/dev/null 2>&1
}


fail2ban_set_ports() {
    local ports
    local IFS=,

    fail2ban_available || return 0

    ports="$*"

    mkdir -p "$(dirname "$F2B_DROPIN")"

    {
        echo "# Written by ssh-port.sh $SCRIPT_VERSION"
        echo "#"
        echo "# fail2ban reads jail.conf, jail.d/*.conf, jail.local and"
        echo "# finally jail.d/*.local. install.sh writes jail.local, so"
        echo "# only a *.local file in jail.d/ is read after it."
        echo
        echo "[sshd]"
        echo "port = $ports"

    } > "$F2B_DROPIN"

    chmod 0644 "$F2B_DROPIN"

    fail2ban_reload "$ports"
}


fail2ban_reload() {
    local ports="$1"

    if ! systemd_is_running; then
        return 0
    fi

    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        return 0
    fi

    if systemctl reload fail2ban >/dev/null 2>&1 ||
       systemctl restart fail2ban >/dev/null 2>&1; then
        echo "  fail2ban: sshd jail now covers port(s) $ports"
    else
        warn "fail2ban did not reload - its sshd jail may still watch the old port."
    fi
}


fail2ban_remove_dropin() {
    [[ -f "$F2B_DROPIN" ]] || return 0

    rm -f "$F2B_DROPIN"

    if systemd_is_running && systemctl is-active --quiet fail2ban 2>/dev/null; then

        if systemctl reload fail2ban >/dev/null 2>&1 ||
           systemctl restart fail2ban >/dev/null 2>&1; then
            echo "  fail2ban: sshd jail back to the port from jail.local"
        else
            warn "fail2ban did not reload - its sshd jail may still watch the old port."
        fi

    fi
}


# ----------------------------------------------------------
# STATE OF AN UNFINISHED CHANGE
# ----------------------------------------------------------

write_state() {
    mkdir -p "$STATE_DIR"
    chmod 0700 "$STATE_DIR"

    cat > "$STATE_FILE" <<EOF
# An SSH port change that has been started but not confirmed.
# Written by ssh-port.sh $SCRIPT_VERSION
OLD_PORTS="$1"
NEW_PORT="$2"
DROPIN_BACKUP="$3"
STARTED="$(date '+%Y-%m-%d %H:%M:%S')"
DEADLINE="$(date -d "+$ROLLBACK_MINUTES minutes" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
EOF

    chmod 0600 "$STATE_FILE"
}


clear_state() {
    rm -f "$STATE_FILE"
}


# ----------------------------------------------------------
# THE SAFETY NET
#
# A transient systemd timer. It belongs to systemd, not to
# this shell, so it fires even when the SSH connection that
# started the change is gone - which is the exact situation it
# exists for.
# ----------------------------------------------------------

arm_rollback() {

    if ! systemd_is_running || ! command -v systemd-run >/dev/null 2>&1; then
        return 1
    fi

    disarm_rollback

    systemd-run \
        --quiet \
        --unit="$ROLLBACK_UNIT" \
        --on-active="${ROLLBACK_MINUTES}min" \
        --description="Undo an unconfirmed SSH port change" \
        "$INSTALLED_COPY" --rollback --from-timer >/dev/null 2>&1
}


disarm_rollback() {
    systemd_is_running || return 0

    systemctl stop "${ROLLBACK_UNIT}.timer"   >/dev/null 2>&1 || true
    systemctl stop "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
    systemctl reset-failed "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
}


# ----------------------------------------------------------
# LOGIN HINT
#
# Printed by pam_motd on every SSH login, for as long as there
# is something to say. It goes quiet by itself once SSH has
# left port 22, and can be switched off by hand.
# ----------------------------------------------------------

write_motd_hint() {

    [[ -d /etc/update-motd.d ]] || return 0

    cat > "$MOTD_HINT" <<'MOTD_EOF'
#!/bin/sh
# Installed by the XRDP + XFCE installer (ssh-port.sh).
#
# Prints a hint while SSH is still on port 22, and a warning
# while a port change is waiting to be confirmed. Silent
# otherwise, so it disappears on its own once the job is done.
#
# Switch it off for good:  touch /etc/xrdp-ssh-port-hint-off
# Remove it:               rm /etc/update-motd.d/99-xrdp-ssh-port

[ -f /etc/xrdp-ssh-port-hint-off ] && exit 0

STATE=/var/lib/xrdp-ssh-port/pending

if [ -f "$STATE" ]; then

    NEW_PORT=$(sed -n 's/^NEW_PORT="\(.*\)"$/\1/p' "$STATE" 2>/dev/null)
    DEADLINE=$(sed -n 's/^DEADLINE="\(.*\)"$/\1/p' "$STATE" 2>/dev/null)

    echo
    echo " ==> An SSH port change is WAITING FOR CONFIRMATION."
    echo
    echo "     New port: ${NEW_PORT:-unknown}   Port 22 is still open."
    echo "     Everything is put back automatically at ${DEADLINE:-the deadline}."
    echo
    echo "     If you are reading this ON the new port, finish it:"
    echo "         sudo xrdp-ssh-port --confirm"
    echo "     To undo it now:"
    echo "         sudo xrdp-ssh-port --rollback"
    echo
    exit 0
fi

command -v ss >/dev/null 2>&1 || exit 0

# Still on 22? Then there is an offer to make.
if [ -n "$(ss -Htnl '( sport = :22 )' 2>/dev/null)" ]; then
    echo
    echo " ==> SSH is on the default port 22, where every bot knocks."
    echo "     You can move it to a port of your choice. The change is"
    echo "     tested from a second terminal first, and port 22 is only"
    echo "     closed once that test worked:"
    echo
    if [ -x /usr/local/sbin/xrdp-ssh-port ]; then
        echo "         sudo xrdp-ssh-port"
    else
        echo "         curl -fsSLo ssh-port.sh https://raw.githubusercontent.com/burnersen/xrdp-xfce-installer/refs/heads/main/ssh-port.sh"
        echo "         sudo bash ssh-port.sh"
    fi
    echo
    echo "     Not interested?  sudo touch /etc/xrdp-ssh-port-hint-off"
    echo
fi

exit 0
MOTD_EOF

    chmod 0755 "$MOTD_HINT"
}


# ----------------------------------------------------------
# SELF INSTALL
#
# The rollback timer calls this script back by an absolute
# path, minutes after the shell that started it may be gone.
# A copy in a fixed place is what makes that possible - and it
# gives the user a command instead of a downloaded file.
# ----------------------------------------------------------

install_self() {
    local self

    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"

    if [[ -z "$self" || ! -f "$self" ]]; then
        echo "ERROR: this script has to run from a file, not from a pipe." >&2
        echo "       curl -fsSLo ssh-port.sh <url>" >&2
        echo "       bash ssh-port.sh" >&2
        exit 1
    fi

    if [[ "$self" != "$INSTALLED_COPY" ]]; then
        install -m 0755 "$self" "$INSTALLED_COPY"
    fi

    if [[ ! -x "$INSTALLED_COPY" ]]; then
        echo "ERROR: could not install $INSTALLED_COPY." >&2
        exit 1
    fi
}


# ----------------------------------------------------------
# WHAT THE SERVER LOOKS LIKE RIGHT NOW
# ----------------------------------------------------------

# The RDP port out of xrdp.ini. The section matters: xrdp.ini
# holds several "port=" lines, and only the one in [Globals]
# is the listening port.
rdp_port() {
    [[ -f /etc/xrdp/xrdp.ini ]] || return 0

    awk '
        /^[[:space:]]*\[/ {
            section = tolower($0)
            sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
            sub(/[[:space:]]*\].*$/, "", section)
            next
        }
        section == "globals" && tolower($0) ~ /^[[:space:]]*port[[:space:]]*=/ {
            split($0, parts, "=")
            gsub(/[[:space:]]/, "", parts[2])
            print parts[2]
            exit
        }' /etc/xrdp/xrdp.ini
}


show_status() {
    local port
    local mechanism
    local -a configured=()

    echo "=================================================="
    echo " SSH port status"
    echo "=================================================="
    echo

    if socket_activated; then

        if [[ -x "$SOCKET_GENERATOR" ]]; then
            mechanism="ssh.socket (ports generated from sshd_config)"
        else
            mechanism="ssh.socket (ports from $SOCKET_DROPIN)"
        fi

    else
        mechanism="ssh.service (ports from sshd_config)"
    fi

    echo " Start mechanism: $mechanism"

    mapfile -t configured < <(sshd_configured_ports)

    echo " Configured port: ${configured[*]:-unknown}"

    echo -n " Really listening:"

    for port in "${configured[@]}"; do
        if port_is_listening "$port"; then
            echo -n " $port"
        else
            echo -n " $port(NO!)"
        fi
    done

    echo

    if port_is_listening "$DEFAULT_SSH_PORT"; then
        echo " Port 22:         still open"
    else
        echo " Port 22:         closed"
    fi

    echo

    if ufw_available; then

        if ufw_is_active; then
            echo " Firewall (ufw):  active"
        else
            echo " Firewall (ufw):  INACTIVE"
        fi

        LC_ALL=C ufw show added 2>/dev/null |
            grep -E "ufw (allow|limit|deny|reject)" |
            sed 's/^/   /' || true

    else
        echo " Firewall (ufw):  not installed"
    fi

    echo

    if fail2ban_available; then
        echo " fail2ban sshd jail port(s):"
        fail2ban-client get sshd port 2>/dev/null | sed 's/^/   /' ||
            echo "   (jail not running)"
    else
        echo " fail2ban:        not installed"
    fi

    if [[ -f "$STATE_FILE" ]]; then
        echo
        echo " --------------------------------------------------"
        echo " A PORT CHANGE IS WAITING FOR CONFIRMATION:"
        echo
        sed 's/^/   /' "$STATE_FILE"
        echo
        echo "   Finish it:  $INSTALLED_COPY --confirm"
        echo "   Undo it:    $INSTALLED_COPY --rollback"
    fi

    echo
}


# ----------------------------------------------------------
# UNDOING AN UNCONFIRMED CHANGE
# ----------------------------------------------------------

do_rollback() {
    local -a old_ports=()
    local port

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "Nothing to roll back - no port change is pending."
        return 0
    fi

    OLD_PORTS=""
    NEW_PORT=""
    DROPIN_BACKUP=""

    # shellcheck disable=SC1090
    source "$STATE_FILE"

    read -r -a old_ports <<< "$OLD_PORTS"

    echo
    echo "Rolling back: SSH goes back to port(s) ${old_ports[*]}."
    echo

    restore_foreign_port_lines

    if [[ -n "$DROPIN_BACKUP" && -f "$DROPIN_BACKUP" ]]; then
        cp -a "$DROPIN_BACKUP" "$SSHD_DROPIN"
    else
        rm -f "$SSHD_DROPIN"
    fi

    remove_socket_dropin

    ensure_run_sshd

    if reload_ssh; then

        for port in "${old_ports[@]}"; do

            if wait_for_listener "$port" "$LISTEN_TIMEOUT"; then
                echo "  port $port: listening again"
            else
                warn "Port $port is NOT listening after the rollback - check 'systemctl status ssh'."
            fi

        done

    else
        warn "The SSH service could not be reloaded during the rollback."
    fi

    for port in "${old_ports[@]}"; do
        ufw_allow_ssh_port "$port" || true
    done

    if [[ -n "$NEW_PORT" ]]; then
        ufw_remove_ssh_port "$NEW_PORT"
    fi

    fail2ban_set_ports "${old_ports[@]}"

    disarm_rollback
    clear_state
    write_motd_hint

    echo
    echo "Rollback finished. SSH is reachable on ${old_ports[*]} again."
    echo
}


# ----------------------------------------------------------
# GOING BACK TO PORT 22 AFTER A FINISHED CHANGE
# ----------------------------------------------------------

do_revert() {
    local -a current=()
    local port

    if [[ -f "$STATE_FILE" ]]; then
        echo "A change is still pending - use --rollback instead."
        return 1
    fi

    mapfile -t current < <(sshd_configured_ports)

    echo
    echo "Putting SSH back on the default port $DEFAULT_SSH_PORT."
    echo "Current port(s): ${current[*]:-unknown}"
    echo

    ufw_allow_ssh_port "$DEFAULT_SSH_PORT" || true

    restore_foreign_port_lines
    rm -f "$SSHD_DROPIN"
    remove_socket_dropin

    ensure_run_sshd
    reload_ssh || warn "The SSH service could not be reloaded."

    if wait_for_listener "$DEFAULT_SSH_PORT" "$LISTEN_TIMEOUT"; then
        echo "  port $DEFAULT_SSH_PORT: listening"
    else
        warn "Port $DEFAULT_SSH_PORT is not listening - do NOT close your session, check 'systemctl status ssh'."
    fi

    for port in "${current[@]}"; do

        [[ "$port" == "$DEFAULT_SSH_PORT" ]] && continue

        if port_is_listening "$port"; then
            warn "Port $port is still listening - its firewall rule was kept."
            continue
        fi

        ufw_remove_ssh_port "$port"

    done

    fail2ban_remove_dropin
    write_motd_hint

    echo
    echo "SSH is back on port $DEFAULT_SSH_PORT."
    echo
}


# ----------------------------------------------------------
# THE CHANGE ITSELF
# ----------------------------------------------------------

validate_port() {
    local port="$1"
    local reserved
    local rdp
    local listener

    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]]; then
        echo "ERROR: '$port' is not a port number."
        return 1
    fi

    # Strip leading zeros here, not later: everything below this
    # line compares and looks up the value, and "02222" would
    # reach "ss" as a string it does not have to understand.
    port="$(( 10#$port ))"

    if (( port < MIN_UNPRIVILEGED_PORT || port > 65535 )); then
        echo "ERROR: choose a port between $MIN_UNPRIVILEGED_PORT and 65535."
        echo "       Below $MIN_UNPRIVILEGED_PORT the system services live."
        return 1
    fi

    for reserved in $RESERVED_PORTS; do

        if (( port == reserved )); then
            echo "ERROR: port $port belongs to another common service."
            return 1
        fi

    done

    rdp="$(rdp_port || true)"

    if [[ -n "$rdp" ]] && (( port == 10#$rdp )); then
        echo "ERROR: port $port is the RDP port of this server."
        return 1
    fi

    if port_is_listening "$port"; then
        listener="$(listener_on_port "$port")"
        echo "ERROR: port $port is already in use:"
        echo "  $listener"
        return 1
    fi

    return 0
}


server_address() {
    local server

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r _ _ server _ <<< "$SSH_CONNECTION"
        echo "$server"
        return 0
    fi

    ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }' ||
        true
}


# Phase 2. The heart of the whole thing.
#
# Not "press a key when it works" - the script looks for an
# ESTABLISHED connection on the new port itself. Loopback does
# not count, so an "ssh localhost" on the server proves
# nothing. Only a real login from outside does.
watch_for_login() {
    local port="$1"
    local waited=0
    local peers=""

    # Stop well before the rollback timer fires, so the user is
    # never surprised by it mid answer.
    local max=$(( (ROLLBACK_MINUTES - 3) * 60 ))
    (( max < 60 )) && max=60

    while (( waited < max )); do

        peers="$(peers_on_port "$port")"

        if [[ -n "$peers" ]]; then
            echo
            echo "  Connection on port $port detected from:"
            echo "$peers" | sed 's/^/    /'
            return 0
        fi

        sleep 3
        waited=$(( waited + 3 ))

        if (( waited % 30 == 0 )); then
            echo "  still waiting... (${waited}s of ${max}s)"
        fi

    done

    return 1
}


# Phase 3. Everything here takes something away, so it only
# runs after the new port has been proven to work.
finish_change() {
    local new_port="$1"
    shift
    local -a old_ports=("$@")
    local port

    echo
    echo "[3/3] Closing the old port(s): ${old_ports[*]}"
    echo

    if ! apply_ssh_ports "$new_port"; then
        echo "ERROR: sshd would not take the new configuration." >&2
        do_rollback
        exit 1
    fi

    for port in "${old_ports[@]}"; do

        if assert_not_listening "$port"; then
            echo "  port $port: closed"
        else
            warn "Port $port is STILL listening. Something outside this script opens it - check 'ss -tlnp | grep :$port'."
        fi

    done

    for port in "${old_ports[@]}"; do
        ufw_remove_ssh_port "$port"
    done

    fail2ban_set_ports "$new_port"

    disarm_rollback
    clear_state
    write_motd_hint
}


do_change() {
    local -a old_ports=()
    local -a both_ports=()
    local new_port=""
    local answer=""
    local listen_addr=""
    local dropin_backup=""
    local server
    local login_user
    local port

    echo "=================================================="
    echo " SSH port change $SCRIPT_VERSION"
    echo "=================================================="
    echo

    # ---- what is there now ----

    mapfile -t old_ports < <(sshd_configured_ports)

    if (( ${#old_ports[@]} == 0 )); then
        echo "ERROR: the current SSH port could not be determined." >&2
        echo "       'sshd -T' produced nothing. Check 'sshd -t'." >&2
        exit 1
    fi

    if socket_activated; then

        echo "This server starts sshd through ssh.socket."

        if [[ -x "$SOCKET_GENERATOR" ]]; then
            echo "Its ports are generated from sshd_config, which is what"
            echo "this script will set."
        else
            echo "There is no socket generator here, so the ports are"
            echo "written into $SOCKET_DROPIN as well."
        fi

    else
        echo "This server starts sshd as a plain service."
    fi

    echo
    echo "Current SSH port(s): ${old_ports[*]}"

    for port in "${old_ports[@]}"; do

        if ! port_is_listening "$port"; then
            warn "sshd is configured for port $port, but nothing is listening there."
        fi

    done

    # ---- the one setup this script refuses ----

    listen_addr="$(listenaddress_with_port || true)"

    if [[ -n "$listen_addr" ]]; then
        echo >&2
        echo "ERROR: this sshd has ListenAddress lines with their own port:" >&2
        echo "$listen_addr" | sed 's/^/  /' >&2
        echo >&2
        echo "Such a line overrides Port completely, and on a socket" >&2
        echo "activated Ubuntu the generator then produces nothing at" >&2
        echo "all - sshd_config would say one thing and the socket" >&2
        echo "another. Changing the port automatically is not safe here." >&2
        echo >&2
        echo "Edit those ListenAddress lines by hand, or drop the port" >&2
        echo "from them so they follow Port again, and run this script" >&2
        echo "afterwards." >&2
        exit 1
    fi

    if ! systemd_is_running; then
        echo >&2
        echo "ERROR: systemd is not running." >&2
        echo "       Without it there is no timer to undo a failed" >&2
        echo "       change, and that safety net is the point of this" >&2
        echo "       script." >&2
        exit 1
    fi

    # ---- the new port ----

    echo
    echo "Pick a port between $MIN_UNPRIVILEGED_PORT and 65535."
    echo "Anything unremarkable will do - the point is to be off 22,"
    echo "where the scanners are."
    echo

    while true; do

        read -rp "New SSH port: " new_port < /dev/tty

        if validate_port "$new_port"; then
            break
        fi

    done

    new_port="$(( 10#$new_port ))"

    # ---- what is about to happen ----

    server="$(server_address || true)"
    login_user="${SUDO_USER:-${USER:-root}}"

    echo
    echo "--------------------------------------------------"
    echo " Plan"
    echo
    echo "  1. sshd starts listening on $new_port AS WELL AS ${old_ports[*]}."
    echo "     ufw opens $new_port, fail2ban watches both."
    echo
    echo "  2. You open a SECOND terminal and log in on $new_port."
    echo "     This script waits until it has SEEN that login."
    echo
    echo "  3. Only then ${old_ports[*]} is closed - in sshd, in ufw"
    echo "     and in fail2ban."
    echo
    echo " If this connection dies in between, everything is put"
    echo " back automatically after $ROLLBACK_MINUTES minutes."
    echo
    echo " Your open sessions are never dropped: ufw lets established"
    echo " connections through, and Ubuntu's ssh.service is configured"
    echo " with KillMode=process, so a restart leaves them alone."
    echo "--------------------------------------------------"
    echo

    if ! ufw_available; then
        echo "NOTE: ufw is not installed. Nothing here blocks the new"
        echo "      port, but nothing protects the server either."
    elif ! ufw_is_active; then
        echo "NOTE: ufw is installed but INACTIVE. The rule is added"
        echo "      anyway, so it is correct once you enable it."
    fi

    echo "NOTE: a firewall at your PROVIDER (Hetzner, AWS, Oracle, ...)"
    echo "      cannot be seen from inside this server. If port $new_port"
    echo "      is closed there, the test in step 2 simply will not"
    echo "      connect - and nothing is lost, because port ${old_ports[*]}"
    echo "      stays open until it does."
    echo

    read -rp "Start the change? [y/N]: " answer < /dev/tty

    if ! [[ "${answer:-N}" =~ ^[Yy]$ ]]; then
        echo "Nothing was changed."
        exit 0
    fi

    # ---- phase 1: add, take nothing away ----

    echo
    echo "[1/3] Opening port $new_port next to ${old_ports[*]}"
    echo

    install_self
    mkdir -p "$BACKUP_DIR"

    if [[ -f "$SSHD_DROPIN" ]]; then
        dropin_backup="$BACKUP_DIR/$(basename "$SSHD_DROPIN").$TIMESTAMP"
        cp -a "$SSHD_DROPIN" "$dropin_backup"
        echo "Backup: $dropin_backup"
    fi

    backup_file "$SSHD_CONFIG"

    # The state and the timer come BEFORE the first change, so
    # that a change which dies halfway is still covered.
    write_state "${old_ports[*]}" "$new_port" "$dropin_backup"

    if arm_rollback; then
        echo "  safety net: everything is undone in $ROLLBACK_MINUTES minutes unless confirmed"
    else
        warn "No rollback timer could be armed - a failed change will NOT undo itself."
    fi

    trap 'echo; echo "Interrupted - rolling back."; do_rollback; exit 130' INT TERM

    neutralise_foreign_port_lines

    # The firewall first: a port sshd listens on but ufw blocks
    # would fail the test in step 2 for the wrong reason.
    ufw_allow_ssh_port "$new_port" || true

    both_ports=("$new_port" "${old_ports[@]}")

    fail2ban_set_ports "${both_ports[@]}"

    if ! apply_ssh_ports "${both_ports[@]}"; then
        echo >&2
        echo "ERROR: sshd did not come up on port $new_port." >&2
        do_rollback
        exit 1
    fi

    write_motd_hint

    # ---- phase 2: prove it ----

    echo
    echo "[2/3] Now test the new port"
    echo
    echo "  Leave THIS terminal open. Do not close it."
    echo
    echo "  On your own computer, open a SECOND terminal and run:"
    echo
    echo "      ssh -p $new_port $login_user@${server:-<SERVER_IP>}"
    echo
    echo "  This script is watching port $new_port and continues by"
    echo "  itself as soon as that login arrives. A connection from"
    echo "  the server to itself does not count."
    echo

    while true; do

        if watch_for_login "$new_port"; then
            break
        fi

        echo
        echo "  No login on port $new_port arrived."
        echo
        echo "  The usual reason is a firewall at your provider that"
        echo "  still blocks $new_port."
        echo

        read -rp "  [w]ait some more, or [r]oll back? [w/R]: " answer < /dev/tty

        if ! [[ "${answer:-R}" =~ ^[Ww]$ ]]; then
            do_rollback
            exit 0
        fi

        # The clock is restarted, or the timer would fire in the
        # middle of the second attempt.
        arm_rollback || warn "The rollback timer could not be re-armed."

    done

    echo
    echo "  The new port works."
    echo

    read -rp "Close port ${old_ports[*]} now? Type YES: " answer < /dev/tty

    if [[ "$answer" != "YES" ]]; then
        echo
        echo "Not confirmed - rolling back."
        do_rollback
        exit 0
    fi

    # ---- phase 3: take the old one away ----

    finish_change "$new_port" "${old_ports[@]}"

    trap - INT TERM

    print_summary "$new_port" "${old_ports[@]}"
}


# Finishing a change from a session that is already ON the new
# port - for when the terminal that started it is gone.
do_confirm() {
    local -a old_ports=()
    local peers

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "No port change is waiting for confirmation."
        return 0
    fi

    OLD_PORTS=""
    NEW_PORT=""
    DROPIN_BACKUP=""

    # shellcheck disable=SC1090
    source "$STATE_FILE"

    read -r -a old_ports <<< "$OLD_PORTS"

    peers="$(peers_on_port "$NEW_PORT")"

    if [[ -z "$peers" ]]; then
        echo "ERROR: nothing is connected on port $NEW_PORT right now." >&2
        echo >&2
        echo "       --confirm is meant to be run FROM a session on the" >&2
        echo "       new port: the connection you are typing this in is" >&2
        echo "       the proof that the port works." >&2
        echo >&2
        echo "       Log in with  ssh -p $NEW_PORT <user>@<server>  and" >&2
        echo "       run it again, or undo the change with --rollback." >&2
        return 1
    fi

    echo
    echo "Connection on port $NEW_PORT from:"
    echo "$peers" | sed 's/^/  /'

    finish_change "$NEW_PORT" "${old_ports[@]}"

    print_summary "$NEW_PORT" "${old_ports[@]}"
}


print_summary() {
    local new_port="$1"
    shift
    local -a old_ports=("$@")
    local warning

    echo
    echo "=================================================="
    echo " SSH now listens on port $new_port"
    echo
    echo " Connect with:"
    echo "   ssh -p $new_port <user>@<server>"
    echo
    echo " Put it in ~/.ssh/config on your own computer and you"
    echo " never have to type it again:"
    echo
    echo "   Host myserver"
    echo "       HostName <server>"
    echo "       Port     $new_port"
    echo "       User     <user>"
    echo
    echo " Port ${old_ports[*]} is closed."
    echo
    echo " Useful commands:"
    echo "   xrdp-ssh-port --status     what is open right now"
    echo "   xrdp-ssh-port --revert     back to port 22"
    echo "   fail2ban-client status sshd"
    echo
    echo " Changed files:"
    echo "   $SSHD_DROPIN"
    echo "   $F2B_DROPIN"
    echo "   Backups in $BACKUP_DIR"

    if (( ${#WARNINGS[@]} > 0 )); then

        echo
        echo " --------------------------------------------------"
        echo " ${#WARNINGS[@]} step(s) need a look:"
        echo

        for warning in "${WARNINGS[@]}"; do
            echo "   - $warning"
        done

    fi

    echo
    echo "=================================================="
}


# ----------------------------------------------------------
# COMMAND LINE
# ----------------------------------------------------------

usage() {
    cat <<USAGE_EOF
ssh-port.sh $SCRIPT_VERSION - move SSH to a port of your choice

  bash ssh-port.sh              change the port (asks, tests, then closes 22)
  xrdp-ssh-port --status        what is configured and what really listens
  xrdp-ssh-port --confirm       finish a pending change from a session
                                that is already on the new port
  xrdp-ssh-port --rollback      undo a change that is not confirmed yet
  xrdp-ssh-port --revert        go back to port 22 after a finished change
  xrdp-ssh-port --help          this text

The port is never changed blindly: sshd listens on the old and
the new port at the same time until a real login on the new one
has been seen. If that login never arrives, a systemd timer puts
everything back within $ROLLBACK_MINUTES minutes.
USAGE_EOF
}


ACTION="change"
FROM_TIMER=false

while (( $# > 0 )); do

    case "$1" in
        --status)     ACTION="status" ;;
        --rollback)   ACTION="rollback" ;;
        --revert)     ACTION="revert" ;;
        --confirm)    ACTION="confirm" ;;
        --from-timer) FROM_TIMER=true ;;
        -h|--help)    usage; exit 0 ;;
        *)
            echo "ERROR: unknown option '$1'" >&2
            echo >&2
            usage >&2
            exit 1
            ;;
    esac

    shift

done


# ----------------------------------------------------------
# CHECKS
# ----------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run as root." >&2
    echo "Example: sudo -i" >&2
    exit 1
fi

if ! command -v ss >/dev/null 2>&1; then
    echo "ERROR: 'ss' is missing (package iproute2)." >&2
    echo "       Without it a port change could not be verified," >&2
    echo "       and an unverified port change is how people lock" >&2
    echo "       themselves out." >&2
    exit 1
fi

if [[ ! -x "$(sshd_binary)" ]]; then
    echo "ERROR: sshd was not found - is openssh-server installed?" >&2
    exit 1
fi

if [[ -r /etc/os-release ]]; then

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        warn "This script is written for Ubuntu. Found '${ID:-unknown}' - the socket activation handling may not fit."
    fi

fi

if [[ "$ACTION" == "change" ]] && ! true </dev/tty 2>/dev/null; then
    echo "ERROR: An interactive TTY is required." >&2
    exit 1
fi


# ----------------------------------------------------------
# GO
# ----------------------------------------------------------

case "$ACTION" in

    status)
        show_status
        ;;

    rollback)
        if [[ "$FROM_TIMER" == true ]]; then
            echo "The confirmation did not arrive in time - undoing the SSH port change."
        fi
        do_rollback
        ;;

    revert)
        # In a "||" list, so a handled refusal inside the function
        # returns an exit code instead of tripping the ERR trap and
        # printing a crash report for something that did not crash.
        do_revert || exit 1
        ;;

    confirm)
        do_confirm || exit 1
        ;;

    change)
        do_change
        ;;

esac
