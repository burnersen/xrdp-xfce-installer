```markdown
# XRDP + XFCE Installer

One-click installer for XRDP + XFCE on Ubuntu with firewall hardening and IP-restricted RDP access.

This script installs a lightweight XFCE desktop environment, enables Remote Desktop (RDP) through XRDP, creates a non-root sudo user, installs browsers, and secures the server using UFW.

---

## Features

- System update and upgrade
- Lightweight XFCE desktop environment
- XRDP remote desktop access
- Creation of a non-root sudo user
- Automatic XFCE session configuration
- UFW firewall hardening
- RDP access restricted to a single IPv4 address by default
- Automatic detection and preservation of the active SSH port
- Removal of old RDP firewall rules before applying the new rule
- Polkit configuration to prevent common XRDP authentication popups
- Installation of Google Chrome on amd64/x86_64
- Installation of Chromium on other supported architectures
- Installation of Firefox when available
- Verification of XRDP and XRDP Session Manager services
- Interactive one-command installer

---

## Supported Systems

- Ubuntu 20.04 or newer
- amd64 / x86_64
- arm64

Other Linux distributions are not supported.

The script is intended for clean or minimal Ubuntu installations.

---

## Security

RDP access on port `3389` is restricted to a single IPv4 address by default.

During installation, you will be asked:

```text
Restrict RDP access to one IPv4 address? [Y/n]:
```

Pressing `Enter` or choosing `Y` requires you to specify the public IPv4 address that is allowed to connect.

Example:

```text
203.0.113.10
```

The resulting firewall rule will be equivalent to:

```bash
ufw allow from 203.0.113.10 to any port 3389 proto tcp
```

All other IP addresses will be blocked from accessing RDP.

If you choose to expose RDP publicly, the installer displays a warning and requires you to explicitly type:

```text
OPEN
```

before allowing port `3389` from any IP address.

The installer also detects and preserves the SSH port used by the current SSH connection before enabling UFW.

---

## Installation

Run the installer as root:

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/Alishka1408/xrdp-xfce-installer/refs/heads/main/install.sh)
```

The installer is interactive and will ask for:

- RDP username
- Whether RDP should be restricted to one IPv4 address
- Allowed IPv4 address
- Password for the RDP user

After installation, reboot the server:

```bash
reboot
```

Then connect using an RDP client:

```text
SERVER_IP:3389
```

Log in with the username and password created during installation.

---

## Browser Installation

### Google Chrome

Google Chrome is installed automatically on:

```text
amd64 / x86_64
```

Google does not provide an official Linux Chrome package for ARM64.

On other supported architectures, the installer attempts to install Chromium instead.

### Firefox

The installer also attempts to install Firefox.

On modern Ubuntu releases, Firefox may be installed through Snap.

On some minimal VPS or container environments, Snap may be unavailable or unsupported. In that case, Firefox installation may fail without affecting the XRDP/XFCE installation.

Browser installation failures are treated as non-fatal.

---

## Firewall Behavior

The installer configures UFW with:

```text
Incoming: deny by default
Outgoing: allow by default
```

SSH access is preserved automatically.

Before creating a new RDP firewall rule, the installer removes existing UFW rules for port `3389`.

This prevents an old rule such as:

```text
3389/tcp ALLOW Anywhere
```

from accidentally remaining active when RDP is supposed to be restricted to one IP address.

---

## Existing Users

If the selected username already exists, the installer will not modify it automatically.

It will display a warning and require confirmation before:

- resetting the user's password
- adding the user to the `sudo` group
- configuring the XFCE XRDP session

System accounts and the `root` account cannot be used as the RDP user.

---

## XRDP Session

The installer configures the user's XRDP session to start XFCE automatically:

```bash
exec startxfce4
```

Both services are checked after installation:

```text
xrdp
xrdp-sesman
```

If either service is not running correctly, the installer exits with an error and displays the service status.

---

## Notes

- A reboot is recommended before the first RDP login.
- RDP is restricted to IPv4 addresses only.
- If your public IP address changes, update the UFW rule before reconnecting.
- On macOS RDP clients, keyboard layout or modifier-key mappings may require additional client-side configuration.
- Other Linux distributions are intentionally not supported.
```

