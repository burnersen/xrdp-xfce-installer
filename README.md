# XRDP + XFCE Installer

Interactive installer for a XFCE remote desktop on Ubuntu, with persistent sessions, a configurable RDP port, firewall hardening and fail2ban.

The script installs a lightweight XFCE desktop, makes it reachable over RDP, creates a non-root sudo user, installs browsers and secures the server. It is written for clean Ubuntu installations, for example on a fresh VPS.

Two optional companion scripts complete the setup: `german.sh` for a German system, and `sunshine.sh` for a second desktop that can be streamed with Moonlight. Run them in that order — `install.sh`, then `german.sh`, then `sunshine.sh` — so the streamed desktop comes up with the right language and keyboard from its very first start.

---

## Features

**Desktop and remote access**

- XFCE desktop environment
- XRDP with a configurable port instead of the default 3389
- Persistent sessions: reconnect from any device, any IP and any window size and find the same desktop with all applications still running
- Fixed colour depth, so different clients cannot create several parallel sessions for the same user
- Polkit rules that prevent the usual colord authentication popups

**Security**

- UFW firewall, incoming denied by default, enabled **before** XRDP is installed
- RDP restricted to a single IPv4 address, or publicly accessible after an explicit confirmation
- Automatic detection and preservation of the active SSH port, so the running SSH connection is never locked out
- Optional companion script that moves SSH off port 22, with a test from a second terminal before the old port is closed
- Removal of stale RDP firewall rules before the new rule is applied, including rules left by an earlier run on a different port
- fail2ban for both SSH and XRDP, with a custom XRDP filter that is verified during the installation
- The chosen RDP port is checked against the SSH port and against everything already listening

**Extras**

- Optional fast DNS resolvers, replacing name servers that make every page load slowly
- Optional update policy that moves all upgrades to boot time, so nothing is ever restarted under a running session
- Google Chrome on amd64, Chromium elsewhere
- Firefox from Mozilla's APT repository instead of the Snap build
- FUSE 2, so AppImage applications start without further setup
- Optional JDownloader 2, either as a desktop application or as a systemd service
- `xrdp-session-reset` helper command for the rare case of a stuck session. It spares a Sunshine desktop if one is installed, so resetting RDP does not cost you the Moonlight session

---

## Supported systems

- Ubuntu 20.04 or newer, tested on 24.04 LTS and 26.04 LTS
- amd64 and arm64

Other distributions are not supported.

The installer runs on every release from 20.04 upwards, but only 24.04 and
26.04 have actually been tried. On an older release it says so and continues.
26.04 is the interesting one: it ships XRDP 0.10 instead of 0.9, and the
installer is written for both.

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
- whether the name servers should be replaced
- whether updates should be installed at boot instead of during work
- the password for the RDP user

All questions come first, and nothing is installed or changed until the last one is answered. `Ctrl+C` **during the questions** therefore leaves the system untouched. Once the installation itself is running that no longer holds: interrupting it halfway leaves packages half configured, so let it finish.

If a step that is not essential fails - a download, the name servers, fail2ban - the installer says so, carries on, and lists everything that did not work at the end. Only the desktop, the user account and the firewall are treated as fatal.

Afterwards, reboot and connect with an RDP client:

```text
SERVER_IP:PORT
```

SSH is left on port 22. The installer says so at the end and points at [`ssh-port.sh`](#companion-script-ssh-port), which moves it safely if you want that.

---

## DNS resolvers

Several hosting providers ship name servers that throttle bursts of queries. The effect is easy to misread: a single lookup on the command line answers in milliseconds, downloads run at full speed, and yet almost every web page loads slowly or fails with a timeout.

The reason is the number of names involved. A browser resolves 20 to 50 different hosts while building one page - images, fonts, statistics, advertising. Once a share of those queries is dropped, the resolver waits 5, 10 or 20 seconds for each of them, and the page stalls long before the data transfer would even start.

The installer therefore offers to replace the name servers with:

```text
1.1.1.1     Cloudflare
8.8.8.8     Google
```

This is a question, not a decision taken for you. Answer `n` on a network that already has good resolvers, or in a company network with its own DNS.

The addresses are written into the existing netplan file, not into an additional one. Name servers configured on the link take precedence over anything in `resolved.conf`, and netplan **merges** lists from several files instead of replacing them - an extra file would leave the old servers in first place and change nothing.

Before the change the file is backed up next to the original, and `netplan generate` validates the result before it is applied, so a broken file cannot cut the network connection.

Afterwards the installer resolves two real host names. Some providers block foreign resolvers outright, and without that check the server would be left with no working name resolution at all - the installation would then die at the next `apt` command, with an error that says nothing about the cause. If the lookup fails, the backup is restored automatically and the installation continues with the provider's name servers.

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

Clients then connect using `SERVER_IP:PORT`.

The installer rejects a port that is already listening, that belongs to another common service, or that is the SSH port of this server - SSH is the way back in if RDP ever breaks, and taking its port would cost both at once. A rejected port is simply asked again; a typo does not end the installation.

---

## Firewall and fail2ban

UFW denies incoming traffic by default. SSH stays reachable: the installer takes the port from four sources - the current SSH connection, the effective sshd configuration, the ports of `ssh.socket`, and whatever `sshd` is actually listening on - and allows every one of them. A port that is listed but no longer in use only costs one extra firewall rule; a port that is in use but not listed costs the way back into the server.

`ssh.socket` is the one that is easy to miss. Ubuntu 22.10 and newer start sshd through socket activation, and the listening port then lives in the systemd unit rather than in `sshd_config`. On such a server `sshd -T` reports port 22 while SSH really answers somewhere else entirely - which is exactly the state a server ends up in when its port was moved the way most guides describe it. The installer reads `systemctl cat ssh.socket`, drop-ins included, so the real port is seen.

One more detail: `sshd -T` aborts outright when `/run/sshd` is missing, and on a socket activated server that has not had an SSH connection since boot, it is missing. The installer creates the directory first, so this source does not silently contribute nothing.

The firewall is configured **before** XRDP is installed. A freshly installed xrdp starts on port 3389 immediately, and on a server without a firewall that port would be exposed for the rest of the installation - on the one port that automated scanners try around the clock.

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

Two details make the difference between real protection and the appearance of it, because a jail that matches nothing still reports itself as healthy:

- **The SSH jail is given the real SSH port.** By default fail2ban uses `port = ssh`, so the ban lands on port 22 while the actual port stays open.
- **The SSH jail needs a log file that exists.** Minimal Ubuntu images no longer install rsyslog, so `/var/log/auth.log` may be missing and the jail then never starts. The installer checks and reads the journal instead.

The XRDP filter is verified during the installation: it is run against sample `AUTHFAIL` lines, and against the real log if it already holds any. A filter that matches nothing is reported as a warning rather than left to look fine.

If RDP is publicly accessible, use a long randomly generated password. fail2ban limits brute force attempts, but it is not a substitute for a strong password.

SSH itself is left on port 22 by this script. Moving it is a separate step with its own script - see [Companion script: SSH port](#companion-script-ssh-port).

---

## Updates

Optional, and off by default. Ubuntu normally installs security updates in the background, whenever its timer fires. On a machine that is actually being worked on, that is the wrong moment: a service restarted while a desktop session is open can tear the session down.

Answering `y` moves the work to boot time, which is the one moment when nothing is running yet.

**While the system is running**

- Security updates keep being downloaded and installed, so the machine does not fall behind.
- No service is restarted. `needrestart` only lists what is outdated instead of acting on it.
- XRDP itself is excluded from background upgrades entirely, because upgrading it restarts the service.
- Nothing ever reboots on its own. The reboot is always yours.

**While the system boots**

- `apt upgrade` runs once, before RDP becomes available, and services are restarted normally.
- **SSH does not wait for it.** If an update ever hangs, the machine has to stay reachable - that is the whole point of not letting RDP be the only way in.
- `upgrade`, not `full-upgrade`: nothing is ever removed.
- The service gives up after 30 minutes, and it gives up after 90 seconds if name resolution is not working yet.

```bash
tail -n 20 /var/log/xrdp-boot-update.log   # what happened last time
xrdp-boot-update                           # update now, without rebooting
```

Two things worth knowing before choosing this:

- A new kernel installed at boot only becomes active on the **next** reboot. That is unavoidable if nothing may reboot on its own.
- Between two reboots the machine gets security updates but no restarts, so a fix in a running service only takes effect once you restart. On a server that stays up for months with a public RDP port, reboot occasionally.

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

## Companion script: SSH port

`ssh-port.sh` moves SSH from port 22 to a port of your choice. Run it after `install.sh`.

```bash
curl -fsSLo ssh-port.sh https://raw.githubusercontent.com/burnersen/xrdp-xfce-installer/refs/heads/main/ssh-port.sh
bash ssh-port.sh
```

Changing the SSH port is the one piece of server hardening that regularly ends with the admin locked out of their own machine, so this is a separate script rather than a question during the installation. It never closes a door before you have walked through the new one.

**How it runs**

1. sshd starts listening on the new port **as well as** the old one. UFW opens the new port and fail2ban is told about both. Nothing is taken away yet.
2. You open a **second terminal** and log in on the new port. The script watches port 22's replacement itself and continues only once it has seen a real, established connection from outside. A connection from the server to itself does not count.
3. Only then is the old port closed - in sshd, in the firewall and in fail2ban.

If the terminal running the script dies between step 1 and step 3, a systemd timer puts everything back within 15 minutes. If you reconnect on the new port before that, `xrdp-ssh-port --confirm` finishes the job from there.

```bash
xrdp-ssh-port --status      # what is configured, and what really listens
xrdp-ssh-port --confirm     # finish a pending change from a session on the new port
xrdp-ssh-port --rollback    # undo a change that is not confirmed yet
xrdp-ssh-port --revert      # go back to port 22 after a finished change
```

**Why this is not `sed -i s/22/2222/ sshd_config`**

Ubuntu 22.10 and newer start sshd through **socket activation**. The listening port then comes from the systemd unit `ssh.socket`, not from `sshd_config`. Editing only `sshd_config` on such a system changes nothing at all - and closing port 22 in the firewall afterwards is exactly how the door shuts behind you.

Ubuntu ships `/usr/lib/systemd/system-generators/sshd-socket-generator` for this. It reads `Port` out of `sshd_config` and writes the matching `ListenStream=` lines for `ssh.socket`, and it runs on `systemctl daemon-reload`. Where that generator exists, setting `Port` and reloading is the supported way; where it does not, the script writes the `ssh.socket` drop-in itself. Either way the result is then checked with `ss`: a port that is not really listening is rolled back instead of believed.

**What else has to follow the port**

- **UFW.** A new port nobody may reach is not a new port. The rule is added before sshd is reloaded, so the test in step 2 cannot fail for the wrong reason.
- **fail2ban.** Its sshd jail bans per port - on Ubuntu 24.04 the nftables rule literally contains `dport { 22 }`. A jail left pointing at 22 keeps running, reports itself as healthy, and bans nobody. The new port is written to `/etc/fail2ban/jail.d/99-xrdp-ssh-port.local`, because fail2ban reads `jail.conf`, `jail.d/*.conf`, `jail.local` and then `jail.d/*.local` - and `install.sh` writes `jail.local`, so only a `.local` file inside `jail.d/` is read after it.
- **Other `Port` lines.** cloud-init writes `/etc/ssh/sshd_config.d/50-cloud-init.conf`, and `Port` is one of the few sshd keywords that add up instead of overriding each other. Such a line would quietly hold port 22 open after the firewall rule for it was removed, so the script comments it out - with a backup, and with a marker so `--revert` puts it back exactly as it was.
- **Your provider's firewall.** A Hetzner, AWS or Oracle firewall cannot be seen from inside the server, so the script cannot check it. It does not have to: if the new port is blocked there, the login in step 2 simply never arrives, nothing is closed, and the change is rolled back.

**What it refuses to do**

If `sshd_config` contains a `ListenAddress` line with its own port, such as `ListenAddress 0.0.0.0:22`, the script stops and explains why. Such a line overrides `Port` completely, and the socket generator then produces nothing at all - `sshd_config` would say one thing and the socket another. A `ListenAddress` without a port follows `Port` and is fine.

**Open sessions are not dropped.** UFW lets established connections through, and Ubuntu's `ssh.service` uses `KillMode=process`, so a restart leaves the sessions that are already open alone.

A reminder about this script is printed on every SSH login for as long as SSH is still on port 22, and goes quiet by itself once it is not. To silence it for good:

```bash
touch /etc/xrdp-ssh-port-hint-off
```

---

## Companion script: German localisation

`german.sh` turns the server into a German system. Run it after `install.sh`.

```bash
curl -fsSLo german.sh https://raw.githubusercontent.com/burnersen/xrdp-xfce-installer/refs/heads/main/german.sh
bash german.sh
```

It sets the system locale to `de_DE.UTF-8`, the time zone to Europe/Berlin, the keyboard layout for console and X11, the session language for one user, and installs the German language pack for Firefox if Mozilla's repository is present.

The **English names of the home directories are kept** — `Downloads` does not become `Downloads`, `Documents` does not become `Dokumente`. Renaming them would break every path another application has stored. This needs more than the `user-dirs.locale` file that most guides mention: that file is only a marker recording which language was used last, and the difference to the running language is exactly what triggers the renaming. The script therefore sets `enabled=False` in `user-dirs.conf`, the documented off switch.

The language applies when a session **starts**. A session that is already running keeps the old language, so reboot or log out inside XFCE and reconnect.

**XRDP is deliberately not restarted.** Restarting it would cut every RDP connection currently open — including the one the script may be running in — without making the language take effect any sooner.

Run this **before** `sunshine.sh`. Both the session language and `/etc/default/keyboard` are picked up by a desktop when it starts, and a keyboard change only becomes visible to an X server that is already running after a reboot. Running it afterwards works too, but then reboot, or run `sunshine-session-reset`, to bring the streamed desktop across.

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

The streamed desktop follows the **system language**: it reads `/etc/default/locale`, the file `localectl` writes, so it comes up German once `german.sh` has run and stays English otherwise. It cannot use `~/.xsessionrc`, because the desktop is started directly and never passes through `/etc/X11/Xsession`.

Running the script a **second time** is fine. If display `:20` is still held by its own services, it says so and offers to stop them first; a display held by anything else is still refused.

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

## When a desktop does not respond

A stuck window manager can leave a session that refuses new connections. SSH still works, so there is a reset command for each desktop. Each one repairs its own half and leaves the other alone:

| Command | Terminates | Leaves alone | Installed by |
|---|---|---|---|
| `xrdp-session-reset` | the RDP session processes | Sunshine, PipeWire | `install.sh` |
| `sunshine-session-reset` | the three `sunshine-*` services | every RDP session | `sunshine.sh` |

If everything is stuck at once, run both — one after the other.

```bash
xrdp-session-reset
```

This terminates the RDP session processes of the desktop user and restarts both XRDP services. Reconnecting then gives a fresh desktop.

It also removes the socket and lock file an X server leaves behind, because a new session on the same display number cannot start while they are there. Only displays with no X server still running are cleaned up, so a display belonging to another service is never touched.

Which processes belong to Sunshine is read from the systemd control groups of its services, not guessed from process names. Without `sunshine.sh` installed there is nothing to spare and every process of the user is terminated, exactly as before.

```bash
sunshine-session-reset
```

This stops the three Sunshine services in reverse order, clears a leftover socket on their display, and starts them again — waiting for the screen to answer instead of guessing a delay. It prints the state of all three at the end.

If SSH is unreachable as well, use the provider's web console. Most VPS providers offer one, and it works independently of the network configuration.

---

## Notes

- A reboot is recommended before the first RDP login.
- The restricted RDP rule covers IPv4 only. IPv6 is not left open by that: incoming traffic is denied by default, so only the public option opens the port for both.
- If the allowed IP address changes, update the UFW rule before reconnecting.
- `MaxSessions=3` is a limit for the whole server, not per user. It is plenty for one person and tight for several.
- Installing `xfce4` pulls in `lightdm`, a login manager for a real monitor. It is useless on a headless server and costs a little memory, but it does not interfere with RDP, which uses display `:10` upwards. Disable it with `systemctl disable lightdm` if it bothers you.
- pCloud and similar applications are not installed by the scripts. FUSE 2 is present, so AppImages run out of the box.
- SSH stays on port 22 after `install.sh`. `ssh-port.sh` moves it, and a reminder is printed on every SSH login until it has been moved or silenced with `touch /etc/xrdp-ssh-port-hint-off`.
- Moonlight has no clipboard sharing between client and server. RDP has.
- On macOS RDP clients, keyboard layout and modifier keys may need additional client-side configuration.

---

## Credits

Based on the [xrdp-xfce-installer](https://github.com/Alishka1408/xrdp-xfce-installer) by Alishka1408, extended with persistent sessions, a configurable RDP port, fail2ban, AppImage support and optional JDownloader installation.
