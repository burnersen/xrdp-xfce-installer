# XRDP + XFCE Installer

Interactive installer for a XFCE remote desktop on Ubuntu, with persistent sessions, a configurable RDP port, firewall hardening and fail2ban.

The script installs a lightweight XFCE desktop, makes it reachable over RDP, creates a non-root sudo user, installs browsers and secures the server. It is written for clean Ubuntu installations, for example on a fresh VPS.

Two optional companion scripts complete the setup: `german.sh` for a German system, and `sunshine.sh` for a second desktop that can be streamed with Moonlight.

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

- Fast DNS resolvers, replacing name servers that make every page load slowly
- Google Chrome on amd64, Chromium elsewhere
- Firefox from Mozilla's APT repository instead of the Snap build
- FUSE 2, so AppImage applications start without further setup
- Optional JDownloader 2, either as a desktop application or as a systemd service
- `xrdp-session-reset` helper command for the rare case of a stuck session

---

## Supported systems

- Ubuntu 20.04 or newer
- amd64 and arm64

Other distributions are not supported.

---

## Installation

Run as root. Download the script first, then execute it:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/burnersen/xrdp-xfce-installer/refs/heads/main/install.sh
bash install.sh
```

If you are not root yet, run `sudo -i` first, as a separate step. Do not paste it together with the commands above: `sudo -i` opens a new shell that swallows the following line.

Downloading first also lets you read the script before running it, which is good practice for anything executed as root.

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

## DNS resolvers

Several hosting providers ship name servers that throttle bursts of queries. The effect is easy to misread: a single lookup on the command line answers in milliseconds, downloads run at full speed, and yet almost every web page loads slowly or fails with a timeout.

The reason is the number of names involved. A browser resolves 20 to 50 different hosts while building one page - images, fonts, statistics, advertising. Once a share of those queries is dropped, the resolver waits 5, 10 or 20 seconds for each of them, and the page stalls long before the data transfer would even start.

The installer therefore replaces the name servers with:

```text
1.1.1.1     Cloudflare
8.8.8.8     Google
```

The addresses are written into the existing netplan file, not into an additional one. Name servers configured on the link take precedence over anything in `resolved.conf`, and netplan **merges** lists from several files instead of replacing them - an extra file would leave the old servers in first place and change nothing.

Before the change the file is backed up next to the original, and `netplan generate` validates the result before it is applied, so a broken file cannot cut the network connection.

`cloud-init` is told to leave the network configuration alone afterwards, because it would otherwise write the provider's name servers back on the next boot:

```text
/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
```

To go back to the provider's name servers, restore the backup and remove that file:

```bash
ls /etc/netplan/                       # find the backup
cp /etc/netplan/50-cloud-init.yaml.backup_* /etc/netplan/50-cloud-init.yaml
rm -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
netplan apply
```

Whether the change took effect is visible per network device, not only globally:

```bash
resolvectl status
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

## Browsers

Google Chrome is installed from Google's own `.deb` package on amd64. On other architectures the installer falls back to Chromium.

Firefox comes from **Mozilla's APT repository**, not from Ubuntu's package. Ubuntu's `firefox` package is only a wrapper that installs the Snap build, and that build misbehaves in a remote session.

The APT pin that comes with it is not optional:

```text
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
```

Without the pin, Ubuntu's wrapper wins the next upgrade and pulls the Snap back in.

---

## JDownloader

Optional, and the installer asks which mode to use.

**Desktop application** runs inside the XFCE session and appears in the menu under Internet. Full GUI, and it works together with a browser on the same machine, which matters for Click'n'Load and for sites that need a logged-in session. It stops when the session is logged out.

**Headless service** runs as a systemd service and starts at boot. No GUI, controlled through my.jdownloader.org. It survives reboots and disconnects.

One detail worth knowing: the desktop mode needs the full JRE. The headless JRE package has no windowing support, so JDownloader falls back to headless mode even with a valid `DISPLAY` and no window ever appears. The installer picks the right package for the selected mode.

The first start is interactive and asks for My JDownloader credentials, so it cannot be automated. The installer prints the exact command at the end.

---

## Companion script: German localisation

`german.sh` turns the server into a German system. Run it after `install.sh`.

```bash
curl -fsSLo german.sh https://raw.githubusercontent.com/burnersen/xrdp-xfce-installer/refs/heads/main/german.sh
bash german.sh
```

It sets the system locale to `de_DE.UTF-8`, the time zone to Europe/Berlin, the keyboard layout for console and X11, the session language for one user, and installs the German language pack for Firefox if Mozilla's repository is present.

The language applies when a session **starts**. A session that is already running keeps the old language, so reboot or log out inside XFCE and reconnect.

---

## Companion script: Sunshine and Moonlight

`sunshine.sh` adds a **second** desktop that is streamed with [Sunshine](https://github.com/LizardByte/Sunshine) and watched with a Moonlight client. Video playback is noticeably smoother than over RDP, because the picture is encoded as a video stream instead of being sent as changed screen regions.

```bash
curl -fsSLo sunshine.sh https://raw.githubusercontent.com/burnersen/xrdp-xfce-installer/refs/heads/main/sunshine.sh
bash sunshine.sh
```

The RDP setup is not modified. Three services are created:

```text
sunshine-xorg      Xorg with the dummy driver on display :20
sunshine-desktop   XFCE running on that display
sunshine-stream    Sunshine capturing and streaming it
```

**Xorg with the dummy driver, not Xvfb.** This is the single most important detail. Xvfb accepts no input devices at all: Sunshine creates its mouse and keyboard as virtual `uinput` devices the moment a client connects, and under Xvfb those are silently discarded. The picture arrives, nothing can be operated. A real X server picks them up through udev. For the same reason `AutoAddDevices` must stay at `true`, although many headless guides recommend turning it off.

**In the Moonlight client, "optimize mouse for remote desktop" has to be switched off.** With that setting the client sends absolute positions, which do not arrive at the server - the picture runs, but the pointer never moves. This is a client setting; the server cannot correct it.

The script also sets up a virtual audio output over PipeWire, because a server has no sound card and the stream would otherwise be silent.

The web interface on port 47990 is deliberately **not** opened in the firewall. It is the only way to reconfigure Sunshine, so it is reached from the server itself:

```text
https://localhost:47990
```

either from a browser on the RDP desktop, or through an SSH tunnel:

```bash
ssh -L 47990:localhost:47990 root@SERVER_IP
```

Open the PIN page **before** clicking connect in Moonlight. Otherwise the attempts expire and block each other with error 409.

Two limitations worth knowing:

- RDP and Moonlight show **different** desktops. The files are the same, the running applications are not. Programs that allow only one instance per user, such as browsers, therefore do nothing when started on the second desktop while they are already open on the first. The script can create launchers with separate profiles for the common ones.
- Gamepads need the `uhid` kernel module, which many VPS kernels do not provide. Mouse and keyboard use `uinput` and are not affected.

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
- pCloud and similar applications are not installed by the scripts. FUSE 2 is present, so AppImages run out of the box.
- Moonlight has no clipboard sharing between client and server. RDP has.
- On macOS RDP clients, keyboard layout and modifier keys may need additional client-side configuration.

---

## Credits

Based on the [xrdp-xfce-installer](https://github.com/Alishka1408/xrdp-xfce-installer) by Alishka1408, extended with persistent sessions, a configurable RDP port, fail2ban, AppImage support and optional JDownloader installation.
