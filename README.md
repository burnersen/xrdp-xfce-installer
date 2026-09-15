# XRDP + XFCE Installer

Interactive installer for a XFCE remote desktop on Ubuntu, with persistent sessions, a configurable RDP port, firewall hardening and fail2ban.

The script installs a lightweight XFCE desktop, makes it reachable over RDP, creates a non-root sudo user, installs browsers and secures the server. It is written for clean Ubuntu installations, for example on a fresh VPS.

---

## Features

**Desktop and remote access**

- XFCE desktop environment
- XRDP with a configurable port instead of the default 3389
- Persistent sessions: reconnect from any device, any IP and any window size and find the same desktop with all applications still running
- Fixed colour depth, so different clients cannot create several parallel sessions for the same user
- Polkit rules that prevent the usual colord authentication popups

**Security**

- UFW firewall, incoming denied by default
- RDP restricted to a single IPv4 address, or publicly accessible after an explicit confirmation
- Automatic detection and preservation of the active SSH port, so the running SSH connection is never locked out
- Removal of stale RDP firewall rules before the new rule is applied
- fail2ban for both SSH and XRDP, with a custom XRDP filter

**Extras**

- FUSE 2, so AppImage applications start without further setup
- Optional JDownloader 2, either as a desktop application or as a systemd service
- `xrdp-session-reset` helper command for the rare case of a stuck session
- Google Chrome on amd64, Chromium elsewhere, Firefox where available

---

## Supported systems

- Ubuntu 20.04 or newer
- amd64 and arm64

Other distributions are not supported.

---

## Installation

The script must run as root.

### Via SSH as root

Most VPS providers give you a root SSH login out of the box. In that case just download the script and run it:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/burnersen/xrdp-xfce-installer/refs/heads/main/install.sh
bash install.sh
```

### Via SSH as a regular user

Some providers log you in as a normal user instead. Switch to root first, as a separate step, then continue as above:

```bash
sudo -i
```

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/burnersen/xrdp-xfce-installer/refs/heads/main/install.sh
bash install.sh
```

Run `sudo -i` on its own and wait for the new prompt. Pasting it together with the following lines does not work: it opens a new shell that swallows whatever comes after it.

### Via the provider's web console

If SSH is unavailable, the same commands work in the browser console offered by most providers. Typing a long URL there is tedious, so this is mainly a fallback.

### Notes on running it

Downloading the script first lets you read it before executing it, which is good practice for anything that runs as root.

On an unstable connection, start `tmux` before the installation. If the connection drops, reconnect and run `tmux attach` to pick the installation up where it left off.

The installer asks for:

- the RDP username
- the RDP port
- whether RDP should be restricted to one IPv4 address
- the allowed IPv4 address, if restricted
- whether JDownloader should be installed, and in which mode
- the password for the RDP user

All questions come before anything is installed, so the installation can be cancelled at any point with `Ctrl+C` without leaving changes behind.

Afterwards, reboot and connect with an RDP client:

```text
SERVER_IP:PORT
```

---

## Persistent sessions

This is the main difference to a plain XRDP setup.

XRDP creates a separate session per colour depth. Different clients negotiate different values, which silently produces several parallel sessions for the same user. One of them ends up holding the desktop while the other shows a blank screen or hangs at "configuring remote computer".

The installer sets:

```text
max_bpp=24                  all clients get the same colour depth
Policy=Default              one session per user
KillDisconnected=false      the session survives a disconnect
DisconnectedTimeLimit=0     a disconnected session never expires
MaxSessions=3               stale sessions surface early
```

The result:

- **Closing** the RDP window keeps everything running. Reconnecting returns the same desktop.
- **Logging out** inside XFCE ends the session and closes everything in it.

If applications need to keep running while nobody is connected, close the window instead of logging out.

---

## RDP port

The default port 3389 is scanned constantly by automated bots. A non standard port above 10000 removes most of that traffic. It is not a security measure on its own, but it keeps the logs readable and the load down.

Clients then connect using `SERVER_IP:PORT`. Ports used by other services are rejected by the installer.

---

## Firewall and fail2ban

UFW denies incoming traffic by default. SSH stays reachable: the installer reads the port of the current SSH connection and the effective sshd configuration, and allows both.

For RDP there are two options.

**Restricted** creates a rule equivalent to:

```bash
ufw allow from 203.0.113.10 to any port PORT proto tcp
```

Everything else is blocked. This is the safer choice, but it is impractical with a changing IP address, for example on mobile data.

**Public** requires typing `OPEN` to confirm and raises the minimum password length to 12 characters. The port is then reachable from anywhere.

fail2ban is installed in both cases. It bans an IP for one hour after five failed logins, for SSH and for XRDP. The port itself stays open for everyone else.

```bash
fail2ban-client status sshd
fail2ban-client status xrdp
fail2ban-client set xrdp unbanip 203.0.113.10
```

Ubuntu ships a filter for SSH only, so the installer creates the XRDP filter. It matches the `AUTHFAIL` line written by `xrdp-sesman`, including the `::ffff:` prefix that an IPv4 address gets inside an IPv6 field.

If RDP is publicly accessible, use a long randomly generated password. fail2ban limits brute force attempts, but it is not a substitute for a strong password.

---

## JDownloader

Optional, and the installer asks which mode to use.

**Desktop application** runs inside the XFCE session and appears in the menu under Internet. Full GUI, and it works together with a browser on the same machine, which matters for Click'n'Load and for sites that need a logged-in session. It stops when the session is logged out.

**Headless service** runs as a systemd service and starts at boot. No GUI, controlled through my.jdownloader.org. It survives reboots and disconnects.

One detail worth knowing: the desktop mode needs the full JRE. The headless JRE package has no windowing support, so JDownloader falls back to headless mode even with a valid `DISPLAY` and no window ever appears. The installer picks the right package for the selected mode.

The first start is interactive and asks for My JDownloader credentials, so it cannot be automated. The installer prints the exact command at the end.

---

## When RDP does not respond

A stuck window manager can leave a session that refuses new connections. SSH still works, so run:

```bash
xrdp-session-reset
```

This terminates the user's processes and restarts both XRDP services. Reconnecting then gives a fresh desktop.

If SSH is unreachable as well, use the provider's web console. Most VPS providers offer one, and it works independently of the network configuration.

---

## Notes

- A reboot is recommended before the first RDP login.
- The firewall rules cover IPv4 only.
- If the allowed IP address changes, update the UFW rule before reconnecting.
- pCloud, Sunshine and similar applications are not installed by the script. FUSE 2 is present, so AppImages run out of the box.
- On macOS RDP clients, keyboard layout and modifier keys may need additional client-side configuration.

---

## Credits

Based on the [xrdp-xfce-installer](https://github.com/Alishka1408/xrdp-xfce-installer) by Alishka1408, extended with persistent sessions, a configurable RDP port, fail2ban, AppImage support and optional JDownloader installation.
