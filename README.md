# VPN Gateway — WireGuard + Wi-Fi AP + LAN

> Turns a Debian/Ubuntu machine with two Wi-Fi adapters into a full VPN router: it connects to the internet over Wi-Fi, routes all traffic through WireGuard, and shares it with clients over its own Wi-Fi and Ethernet.

![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-blue)
![Shell](https://img.shields.io/badge/shell-bash-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

A single `install.sh` brings up the whole stack: WireGuard, hostapd, dnsmasq, NAT, and policy routing. The installation is **idempotent** — re-running skips already-configured components, so you can run the script as many times as you like without breaking anything.

---

## Contents

- [How it works](#how-it-works)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration parameters](#configuration-parameters)
- [Security settings](#security-settings)
- [Telegram notifications](#telegram-notifications)
- [Management and diagnostics](#management-and-diagnostics)
- [File layout](#file-layout)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## How it works

```
   Internet
      │
 [ Wi-Fi router ]
      │  Wi-Fi (WAN, managed by NetworkManager)
      ▼
┌─────────────────────────────────────────────┐
│            VPN Gateway (this host)            │
│                                               │
│   WAN(wlan) ──► WireGuard (wg0) ──► NAT       │
│                      │                        │
│            ┌─────────┴─────────┐              │
│            ▼                   ▼              │
│      AP (Wi-Fi)           LAN (Ethernet)      │
└─────────────────────────────────────────────┘
            │                   │
       📱 Clients          💻 Wired PC
```

The host connects to an existing network over Wi-Fi (**WAN**), all outbound traffic is pushed through the **WireGuard** tunnel, and it's redistributed via a second Wi-Fi card (**AP**, access point) and an **Ethernet port** (LAN). Client routing is handled by a dedicated policy-routing table (table 200) so it doesn't conflict with `wg-quick`.

---

## Features

- **WireGuard client** — keys are generated on the spot, PresharedKey support, manual entry of the server's address/port/public key.
- **Wi-Fi access point** (hostapd) — WPA2, automatic 2.4/5 GHz band selection that skips DFS/radar channels.
- **LAN distribution** over cable with its own subnet and DHCP.
- **DHCP + DNS** via dnsmasq, including MTU delivery to clients.
- **Kill switch** — if the VPN goes down, internet is blocked (fail-closed).
- **DNS leak protection** — DNS queries can't escape outside the tunnel.
- **Client isolation** — Wi-Fi clients can't see the LAN segment.
- **Watchdog** — auto-restarts the VPN when the handshake is lost (checked every 30 seconds via cron).
- **Telegram notifications** — VPN status, client connections, daily statistics.
- **MAC randomization** — for WAN (random/stable/keep) and for the access point BSSID.
- **Deterministic MTU** — `WAN MTU − 80`, without a fragile ICMP probe.
- **Clean iptables** — rules live in dedicated chains (`VPNGW_*`); existing rules are left untouched.
- **Idempotency** — state is stored in `/etc/vpn-gateway.state`; re-running skips what's already done.
- **systemd service** — the gateway comes up automatically after a reboot.

---

## Requirements

| Component | Minimum |
|-----------|---------|
| OS | Ubuntu or Debian (or `ID_LIKE=debian`) |
| Privileges | root (`sudo`) |
| Wi-Fi adapters | **2**: one for WAN, one for AP (with AP mode support) |
| Ethernet | 1 port for LAN |
| WireGuard server access | IP/domain, port, server public key |

> ⚠️ **At least two Wi-Fi adapters** are required. One stays a client to your router (WAN), the other broadcasts the network (AP). The script checks AP-mode support automatically and tags adapters with `[AP✓]` / `[AP✗]`.

Packages are installed automatically: `wireguard`, `hostapd`, `dnsmasq`, `iptables`, `conntrack`, `iw`, `ethtool`, `curl`.

---

## Installation

```bash
github.com/Drejelt/VPN-Gateway-WireGuard-Wi-Fi-AP-LAN.git
cd VPN-Gateway-WireGuard-Wi-Fi-AP-LAN
sudo bash install.sh
```

The script is interactive — it lists the interfaces and walks you through the steps:

1. Interface selection: **WAN** (Wi-Fi client), **AP** (Wi-Fi broadcast), **LAN** (cable).
2. Network and Wi-Fi parameters: access point IP, LAN IP, SSID, password, band.
3. WireGuard setup (keys are generated; the public key must be added on the server).
4. Security options (kill switch, DNS leak protection, isolation, watchdog).
5. (Optional) Telegram notifications.
6. (Optional) connecting WAN to the upstream router over Wi-Fi.

When it finishes, the script asks whether to reboot.

### Re-running

```bash
sudo bash install.sh
```

The script shows the status of every component (`[✓]` / `[ ]`) and skips the ones already configured. Saved answers are offered as defaults.

---

## Configuration parameters

All answers are saved to `/etc/vpn-gateway.conf` (mode `600`). Key parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| Access point IP | `192.168.10.1` | Address/subnet of the Wi-Fi segment |
| LAN IP | `192.168.20.1` | LAN address/subnet (must be a different `/24`) |
| SSID | `MyVPN-WiFi` | Name of the broadcast network |
| Wi-Fi password | — | Minimum 8 characters, hidden input |
| Band | 2.4 GHz | Offers 5 GHz automatically if the adapter supports it |
| Tunnel MTU | `WAN MTU − 80` | Computed automatically, capped at 1420 |
| BSSID randomization | `no` | Stable-random access point MAC |

DHCP hands out addresses in the `.10–.100` (AP) and `.10–.50` (LAN) ranges, with a 12-hour lease.

---

## Security settings

| Option | Default | What it does |
|--------|---------|--------------|
| **Kill switch** | on | Blocks all internet if the VPN is unavailable (fail-closed) |
| **DNS leak protection** | on | All DNS queries go only through the tunnel |
| **Client isolation** | on | Wi-Fi clients can't see the LAN segment |
| **Watchdog** | on | Restarts the VPN when the handshake is lost |

Additionally:
- `rp_filter` is set to **loose (=2)** only on the relevant interfaces — required for policy routing, while keeping basic anti-spoofing protection.
- `wg0.conf`, `hostapd.conf`, `vpn-gateway.conf`, and `vpn-tg.sh` have restricted permissions (`600`/`700`) — secrets aren't exposed.
- Extra Ethernet interfaces are brought down automatically.

---

## Telegram notifications

Optional. What you need:

1. Create a bot: [@BotFather](https://t.me/BotFather) → `/newbot` → get the **token**.
2. Message the bot, then open
   `https://api.telegram.org/bot<TOKEN>/getUpdates` and find your **Chat ID**.
3. Enter the token and Chat ID during the Telegram step — the script immediately sends a test message to verify.

Notification types: VPN connected/down/restored, client connect and disconnect, daily statistics (at 09:00).

---

## Management and diagnostics

```bash
# Service status
systemctl status vpn-gateway hostapd dnsmasq

# WireGuard state
sudo wg show wg0

# Connected Wi-Fi clients
sudo iw dev <ap_iface> station dump

# Current DHCP leases
cat /var/lib/misc/dnsmasq.leases

# Installation component status
cat /etc/vpn-gateway.state

# Logs
tail -f /var/log/vpn-gateway-install.log   # installer
tail -f /var/log/vpn-gateway.log           # gateway
tail -f /var/log/vpn-watchdog.log          # watchdog
```

---

## File layout

| Path | Purpose |
|------|---------|
| `/usr/local/bin/vpn-gateway.sh` | Main script: interfaces, iptables, routes (run by systemd) |
| `/usr/local/bin/vpn-watchdog.sh` | VPN check and auto-restart (cron) |
| `/usr/local/bin/vpn-tg.sh` | Sends Telegram notifications |
| `/etc/hostapd/hostapd-action.sh` | hostapd client event hook |
| `/etc/vpn-gateway.conf` | Saved configuration (`600`) |
| `/etc/vpn-gateway.state` | Installation state (`600`) |
| `/etc/wireguard/wg0.conf` | WireGuard config |
| `/etc/systemd/system/vpn-gateway.service` | Gateway autostart |
| `/etc/systemd/system/vpn-hostapd-notify.service` | Client notifications |

Every system file that gets modified (`NetworkManager.conf`, `/etc/network/interfaces`, `dnsmasq.conf`) is backed up to `*.bak.<timestamp>` before editing.

---

## Troubleshooting

**The script says "No second Wi-Fi adapter for the AP".**
You need two Wi-Fi adapters. Check with `iw dev`. If an adapter is tagged `[AP✗]`, it doesn't support access point mode.

**hostapd won't start on 5 GHz.**
The script picks the first non-DFS/non-radar channel, but if auto-detection fails, choose 2.4 GHz during installation or set the channel manually in `/etc/hostapd/hostapd.conf`.

**Port 53 is busy (dnsmasq won't start).**
The script disables the `systemd-resolved` stub listener itself. If it's held by another service, check `sudo ss -ulpn | grep :53`.

**Clients have no internet.**
Check the handshake: `sudo wg show wg0`. If the kill switch is on and the VPN didn't come up, internet is blocked on purpose. Run `sudo /usr/local/bin/vpn-gateway.sh` and watch the log.

**Reset the installation from scratch.**
Delete `/etc/vpn-gateway.state` (and `/etc/vpn-gateway.conf` if needed), then run `install.sh` again.

---

## License

MIT — see the [LICENSE](LICENSE) file.

> ⚠️ Use on your own devices and within the laws of your country. This project is provided "as is", without warranty.
