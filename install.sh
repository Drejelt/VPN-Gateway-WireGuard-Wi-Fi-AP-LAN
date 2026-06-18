#!/bin/bash
# ============================================================
#  VPN Gateway: WireGuard + hostapd + NAT
#  Debian / Ubuntu
#  Idempotent: re-running skips already-configured components.
# ============================================================

set -euo pipefail

# ── Config ───────────────────────────────────────────────────
STATE_FILE="/etc/vpn-gateway.state"
CONFIG_FILE="/etc/vpn-gateway.conf"
LOG_FILE="/var/log/vpn-gateway-install.log"

COMPONENTS="packages interfaces wifi wireguard mtu security wan_uplink nm interfaces_cfg sysctl apdaemon watchdog_script service"

# ── Logging ──────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "════ Start: $(date '+%Y-%m-%d %H:%M:%S') ════"

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

info()    { echo -e "${BLUE}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
skip()    { echo -e "${CYAN}[~]${NC} $1 — already configured, skipping"; }
header()  { echo -e "\n${BOLD}${BLUE}══ $1 ══${NC}"; }

# ── Error trap ───────────────────────────────────────────────
trap 'error "Error on line $LINENO: $BASH_COMMAND"' ERR

# ── Root check ───────────────────────────────────────────────
[ "$EUID" -ne 0 ] && error "Run this script as root: sudo $0"

# ── Distro check ─────────────────────────────────────────────
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
        error "Only Ubuntu/Debian are supported. Detected: $ID"
    fi
else
    error "Could not determine the distribution"
fi

# ── State ────────────────────────────────────────────────────
touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
is_done()   { grep -q "^$1=done$" "$STATE_FILE" 2>/dev/null; }
mark_done() {
    local tmp; tmp="$(mktemp)"
    grep -v "^$1=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    echo "$1=done" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

# ── Load saved config ────────────────────────────────────────
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# Defaults for all SAVED_* variables (guard against the -u flag)
SAVED_WAN="${SAVED_WAN:-}"
SAVED_AP="${SAVED_AP:-}"
SAVED_LAN="${SAVED_LAN:-}"
SAVED_AP_MAC="${SAVED_AP_MAC:-}"
SAVED_EXTRA_ETH="${SAVED_EXTRA_ETH:-}"
SAVED_SSID="${SAVED_SSID:-}"
SAVED_WIFI_PASS="${SAVED_WIFI_PASS:-}"
SAVED_AP_IP="${SAVED_AP_IP:-}"
SAVED_LAN_IP="${SAVED_LAN_IP:-}"
SAVED_VPN_IP="${SAVED_VPN_IP:-}"
SAVED_VPN_DNS="${SAVED_VPN_DNS:-}"
SAVED_MTU="${SAVED_MTU:-}"
SAVED_HW_MODE="${SAVED_HW_MODE:-}"
SAVED_CHANNEL="${SAVED_CHANNEL:-}"
SAVED_KILL_SWITCH="${SAVED_KILL_SWITCH:-}"
SAVED_DNS_LEAK="${SAVED_DNS_LEAK:-}"
SAVED_CLIENT_ISO="${SAVED_CLIENT_ISO:-}"
SAVED_WATCHDOG="${SAVED_WATCHDOG:-}"
SAVED_TG_TOKEN="${SAVED_TG_TOKEN:-}"
SAVED_TG_CHAT_ID="${SAVED_TG_CHAT_ID:-}"
SAVED_AP_MAC_RANDOM="${SAVED_AP_MAC_RANDOM:-}"
SAVED_WAN_SSID="${SAVED_WAN_SSID:-}"
SAVED_WAN_MAC_MODE="${SAVED_WAN_MAC_MODE:-}"

# Default values (in case sections are skipped — guard against -u)
AP_MAC_RANDOM="${SAVED_AP_MAC_RANDOM:-false}"
WAN_SSID="${SAVED_WAN_SSID:-}"
WAN_MAC_MODE="${SAVED_WAN_MAC_MODE:-keep}"

# ── Helpers ──────────────────────────────────────────────────
ask() {
    # ask "Question" "default" -> pressing Enter uses the default
    local Q="$1" DEF="$2"
    [ -n "$DEF" ] \
        && echo -e "${YELLOW}[?]${NC} $Q ${GRAY}[$DEF]${NC}: " \
        || echo -e "${YELLOW}[?]${NC} $Q: "
}
read_val() {
    local DEF="$1"; read -r _V
    echo "${_V:-$DEF}"
}
read_secret() {
    # read without echo (for passwords/tokens)
    local DEF="$1" _V
    read -rs _V; echo >&2
    echo "${_V:-$DEF}"
}
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
rand_mac() {
    # Random locally-administered unicast MAC (LAA=1, multicast=0) from /dev/urandom
    local hex
    hex=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
    printf '%02x:%s:%s:%s:%s:%s\n' \
        $(( (0x${hex:0:2} & 0xFC) | 0x02 )) \
        "${hex:2:2}" "${hex:4:2}" "${hex:6:2}" "${hex:8:2}" "${hex:10:2}"
}
valid_ip() {
    local ip="$1" n
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=. ; read -ra _oct <<< "$ip"
    for n in "${_oct[@]}"; do (( n >= 0 && n <= 255 )) || return 1; done
    return 0
}
# Pick an item from an array with validation: pick_index <default> <len>
pick_index() {
    local def="$1" len="$2" num
    num="$(read_val "$def")"
    if ! is_uint "$num" || (( num < 1 || num > len )); then
        error "Invalid choice: '$num' (expected 1..$len)"
    fi
    echo "$num"
}

# ══════════════════════════════════════════════════════════════
# BANNER
# ══════════════════════════════════════════════════════════════
clear
echo -e "${BOLD}${BLUE}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   VPN Gateway: WireGuard + WiFi + LAN   ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  OS:   ${GREEN}${PRETTY_NAME}${NC}"
echo -e "  Log:  ${GREEN}${LOG_FILE}${NC}"
echo ""
echo -e "  ${BOLD}Component status:${NC}"
for c in $COMPONENTS; do
    is_done "$c" \
        && echo -e "    ${GREEN}[✓]${NC} $c" \
        || echo -e "    ${RED}[ ]${NC} $c"
done
echo ""
read -rp "  Continue? (y/n): " _CONFIRM
[ "$_CONFIRM" != "y" ] && exit 0

# ══════════════════════════════════════════════════════════════
# 1. PACKAGES
# ══════════════════════════════════════════════════════════════
header "Installing packages"
if is_done "packages"; then skip "packages"
else
    apt update -qq
    # iptables-persistent omitted: rules are applied by vpn-gateway.sh at boot
    apt install -y -qq wireguard hostapd dnsmasq \
        iptables conntrack iw ethtool curl
    success "Packages installed"
    mark_done "packages"
fi

# ══════════════════════════════════════════════════════════════
# 2. INTERFACES — scan and select
# ══════════════════════════════════════════════════════════════
header "Network interfaces"

if is_done "interfaces" && [ -n "${SAVED_WAN:-}" ]; then
    skip "interfaces (WAN=$SAVED_WAN AP=$SAVED_AP LAN=$SAVED_LAN)"
    WAN_IFACE="$SAVED_WAN"
    AP_IFACE="$SAVED_AP"
    LAN_IFACE="$SAVED_LAN"
    AP_MAC="$SAVED_AP_MAC"
    EXTRA_ETH="${SAVED_EXTRA_ETH:-}"
else
    echo ""
    info "Available WiFi adapters:"
    WIFI_LIST=()
    for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
        PHY=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
        SUPPORTS_AP=$(iw phy "$PHY" info 2>/dev/null | grep -c "\* AP" || true); SUPPORTS_AP=${SUPPORTS_AP:-0}
        SUPPORTS_5G=$(iw phy "$PHY" info 2>/dev/null | grep -c "5[0-9][0-9][0-9] MHz" || true); SUPPORTS_5G=${SUPPORTS_5G:-0}
        MAC=$(ethtool -P "$iface" 2>/dev/null | awk '{print $3}')
        [ -z "$MAC" ] && MAC=$(cat /sys/class/net/"$iface"/address 2>/dev/null || true)
        SSID_CUR=$(iw dev "$iface" link 2>/dev/null | awk '/SSID/{print $2}')
        AP_TAG=""; [ "${SUPPORTS_AP:-0}" -gt 0 ] 2>/dev/null && AP_TAG="${GREEN}[AP✓]${NC}" || AP_TAG="${RED}[AP✗]${NC}"
        BAND_TAG=""; [ "${SUPPORTS_5G:-0}" -gt 0 ] 2>/dev/null && BAND_TAG="[2.4+5GHz]" || BAND_TAG="[2.4GHz]"
        WIFI_LIST+=("$iface")
        IDX=${#WIFI_LIST[@]}
        [ -n "$SSID_CUR" ] \
            && echo -e "    $IDX) $(printf '%-22s' "$iface") $AP_TAG $BAND_TAG — '$SSID_CUR' ($MAC)" \
            || echo -e "    $IDX) $(printf '%-22s' "$iface") $AP_TAG $BAND_TAG — free ($MAC)"
    done

    [ ${#WIFI_LIST[@]} -lt 1 ] && error "No Wi-Fi adapter found"

    WAN_DEFAULT=1
    for j in "${!WIFI_LIST[@]}"; do
        [ "${WIFI_LIST[$j]}" = "${SAVED_WAN:-}" ] && WAN_DEFAULT=$((j+1))
    done
    ask "WAN (Wi-Fi client to the router, stays under NetworkManager)" "$WAN_DEFAULT"
    WAN_NUM=$(pick_index "$WAN_DEFAULT" "${#WIFI_LIST[@]}")
    WAN_IFACE="${WIFI_LIST[$((WAN_NUM-1))]}"

    echo ""
    info "AP adapter (will broadcast WiFi):"
    AP_CANDIDATES=(); i=1
    for iface in "${WIFI_LIST[@]}"; do
        [ "$iface" = "$WAN_IFACE" ] && continue
        PHY=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
        SUPPORTS_AP=$(iw phy "$PHY" info 2>/dev/null | grep -c "\* AP" || true); SUPPORTS_AP=${SUPPORTS_AP:-0}
        AP_TAG=""; [ "${SUPPORTS_AP:-0}" -gt 0 ] 2>/dev/null && AP_TAG="${GREEN}[AP✓]${NC}" || AP_TAG="${RED}[AP✗]${NC}"
        SMARK=""; [ "$iface" = "${SAVED_AP:-}" ] && SMARK=" ${GREEN}← saved${NC}"
        echo -e "    $i) $iface $AP_TAG$SMARK"
        AP_CANDIDATES+=("$iface"); i=$((i+1))
    done

    [ ${#AP_CANDIDATES[@]} -lt 1 ] && \
        error "No second Wi-Fi adapter for the AP. At least 2 adapters are required (one WAN, one AP)."

    AP_DEFAULT=1
    for j in "${!AP_CANDIDATES[@]}"; do
        [ "${AP_CANDIDATES[$j]}" = "${SAVED_AP:-}" ] && AP_DEFAULT=$((j+1))
    done
    ask "AP" "$AP_DEFAULT"
    AP_NUM=$(pick_index "$AP_DEFAULT" "${#AP_CANDIDATES[@]}")
    AP_IFACE="${AP_CANDIDATES[$((AP_NUM-1))]}"
    AP_MAC=$(ethtool -P "$AP_IFACE" 2>/dev/null | awk '{print $3}')
    [ -z "$AP_MAC" ] && AP_MAC=$(cat /sys/class/net/"$AP_IFACE"/address 2>/dev/null || true)

    echo ""
    info "LAN interface (cable to a PC):"
    ETH_LIST=(); ALL_ETH=(); i=1
    for iface in $(ip link show | awk -F': ' '/^[0-9]+: e/{print $2}' | cut -d'@' -f1); do
        CARRIER=$(cat /sys/class/net/"$iface"/carrier 2>/dev/null || true)
        MARK=""; [ "$CARRIER" = "1" ] && MARK=" ← cable connected"
        SMARK=""; [ "$iface" = "${SAVED_LAN:-}" ] && SMARK=" ${GREEN}← saved${NC}"
        echo -e "    $i) $iface$MARK$SMARK"
        ETH_LIST+=("$iface"); ALL_ETH+=("$iface"); i=$((i+1))
    done

    [ ${#ETH_LIST[@]} -lt 1 ] && error "No Ethernet interface found for LAN"

    LAN_DEFAULT=1
    for j in "${!ETH_LIST[@]}"; do
        [ "${ETH_LIST[$j]}" = "${SAVED_LAN:-}" ] && LAN_DEFAULT=$((j+1))
    done
    ask "LAN" "$LAN_DEFAULT"
    LAN_NUM=$(pick_index "$LAN_DEFAULT" "${#ETH_LIST[@]}")
    LAN_IFACE="${ETH_LIST[$((LAN_NUM-1))]}"

    EXTRA_ETH=""
    for iface in "${ALL_ETH[@]}"; do
        [ "$iface" = "$LAN_IFACE" ] && continue
        EXTRA_ETH="$EXTRA_ETH $iface"
    done
    EXTRA_ETH="${EXTRA_ETH## }"
    [ -n "$EXTRA_ETH" ] && info "Extra ETH (will be brought down): $EXTRA_ETH"

    success "WAN=$WAN_IFACE  AP=$AP_IFACE  LAN=$LAN_IFACE"
    mark_done "interfaces"
fi

# ══════════════════════════════════════════════════════════════
# 3. NETWORK AND WiFi PARAMETERS
# ══════════════════════════════════════════════════════════════
header "Network and WiFi parameters"

if is_done "wifi" && [ -n "${SAVED_SSID:-}" ]; then
    skip "wifi (SSID=$SAVED_SSID AP_IP=$SAVED_AP_IP LAN_IP=$SAVED_LAN_IP)"
    AP_IP="$SAVED_AP_IP"; AP_NET=$(echo "$AP_IP" | cut -d. -f1-3)
    LAN_IP="$SAVED_LAN_IP"; LAN_NET=$(echo "$LAN_IP" | cut -d. -f1-3)
    SSID="$SAVED_SSID"; WIFI_PASS="$SAVED_WIFI_PASS"
    HW_MODE="$SAVED_HW_MODE"; CHANNEL="$SAVED_CHANNEL"
    AP_MAC_RANDOM="${SAVED_AP_MAC_RANDOM:-false}"
else
    while :; do
        ask "WiFi access point IP" "${SAVED_AP_IP:-192.168.10.1}"
        AP_IP=$(read_val "${SAVED_AP_IP:-192.168.10.1}")
        valid_ip "$AP_IP" || { warn "Invalid IP"; continue; }
        break
    done
    AP_NET=$(echo "$AP_IP" | cut -d. -f1-3)

    while :; do
        ask "LAN port IP" "${SAVED_LAN_IP:-192.168.20.1}"
        LAN_IP=$(read_val "${SAVED_LAN_IP:-192.168.20.1}")
        valid_ip "$LAN_IP" || { warn "Invalid IP"; continue; }
        LAN_NET=$(echo "$LAN_IP" | cut -d. -f1-3)
        [ "$LAN_NET" = "$AP_NET" ] && { warn "LAN and AP must be in different /24 subnets"; continue; }
        break
    done

    ask "SSID" "${SAVED_SSID:-MyVPN-WiFi}"; SSID=$(read_val "${SAVED_SSID:-MyVPN-WiFi}")
    ask "WiFi password (hidden input, min. 8 chars)" ""
    WIFI_PASS=$(read_secret "${SAVED_WIFI_PASS:-}")
    while [ ${#WIFI_PASS} -lt 8 ]; do
        warn "Password too short (minimum 8 characters)!"
        ask "WiFi password" ""; WIFI_PASS=$(read_secret "")
    done

    PHY=$(iw dev "$AP_IFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
    SUPPORTS_5G=$(iw phy "$PHY" info 2>/dev/null | grep -c "5[0-9][0-9][0-9] MHz" || true); SUPPORTS_5G=${SUPPORTS_5G:-0}
    HW_MODE="${SAVED_HW_MODE:-g}"; CHANNEL="${SAVED_CHANNEL:-6}"
    if [ "${SUPPORTS_5G:-0}" -gt 0 ] 2>/dev/null; then
        ask "Use 5 GHz?" "$([ "$HW_MODE" = "a" ] && echo Y || echo n)"
        BAND=$(read_val "$([ "$HW_MODE" = "a" ] && echo Y || echo n)")
        if [[ ! "$BAND" =~ ^[Nn] ]]; then
            HW_MODE="a"
            # Pick the first non-DFS/non-radar/non-disabled channel so hostapd doesn't stall on CAC
            CHANNEL=$(iw phy "$PHY" info 2>/dev/null | grep "MHz" | grep -v "disabled\|radar\|no IR" | \
                awk '{gsub(/[\[\(].*/, ""); gsub(/[^0-9]/, "", $1); if($1>5000) print int(($1-5000)/5)}' | head -1)
            { [ -z "$CHANNEL" ] || [ "$CHANNEL" = "0" ]; } && CHANNEL="36"
        else
            HW_MODE="g"; CHANNEL="6"
        fi
    fi

    # Access point MAC (BSSID) randomization. Stable-random per install:
    # clients don't have to reconnect on every reboot.
    ask "Randomize access point MAC (BSSID)?" "${SAVED_AP_MAC_RANDOM:-n}"
    APR=$(read_val "${SAVED_AP_MAC_RANDOM:-n}")
    if [[ "$APR" =~ ^([Yy]|true)$ ]]; then
        AP_MAC=$(rand_mac); AP_MAC_RANDOM=true
        info "AP BSSID will be: $AP_MAC"
    else
        AP_MAC_RANDOM=false
    fi

    success "SSID=$SSID  AP=$AP_IP  LAN=$LAN_IP  mode=$HW_MODE ch=$CHANNEL  mac_rand=$AP_MAC_RANDOM"
    mark_done "wifi"
fi

# ══════════════════════════════════════════════════════════════
# 4. WIREGUARD
# ══════════════════════════════════════════════════════════════
header "WireGuard"

VPN_DNS=$(grep "^DNS" /etc/wireguard/wg0.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' | cut -d, -f1 || echo "")
VPN_IP=$(grep "^Address" /etc/wireguard/wg0.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' | cut -d/ -f1 | cut -d, -f1 || echo "")

if is_done "wireguard" && [ -f /etc/wireguard/wg0.conf ]; then
    skip "WireGuard (IP=$VPN_IP DNS=$VPN_DNS)"
    VPN_DNS="${VPN_DNS:-${SAVED_VPN_DNS:-1.1.1.1}}"
    VPN_IP="${VPN_IP:-${SAVED_VPN_IP:-10.66.66.2}}"
else
    if [ -f /etc/wireguard/wg0.conf ]; then
        warn "wg0 config already exists"
        ask "Recreate?" "n"; RECREATE=$(read_val "n")
        if [[ "$RECREATE" =~ ^[Nn] ]]; then
            VPN_DNS="${VPN_DNS:-1.1.1.1}"; VPN_IP="${VPN_IP:-10.66.66.2}"
            success "Using the existing config (IP=$VPN_IP DNS=$VPN_DNS)"
            mark_done "wireguard"
        fi
    fi

    if ! is_done "wireguard"; then
        ask "WireGuard server IP/domain" ""; WG_SERVER_IP=$(read_val "")
        [ -z "$WG_SERVER_IP" ] && error "Server IP not provided"
        ask "Port" "51820"; WG_PORT=$(read_val "51820")
        ask "Server public key" ""; WG_SERVER_PUBKEY=$(read_val "")
        [ -z "$WG_SERVER_PUBKEY" ] && error "Public key not provided"
        ask "PresharedKey (if any, otherwise Enter)" ""; WG_PSK=$(read_secret "")
        ask "VPN DNS server" "${SAVED_VPN_DNS:-10.66.66.1}"; VPN_DNS=$(read_val "${SAVED_VPN_DNS:-10.66.66.1}")
        ask "This device's IP inside the tunnel" "${SAVED_VPN_IP:-10.66.66.2}"; VPN_IP=$(read_val "${SAVED_VPN_IP:-10.66.66.2}")

        WG_PRIVKEY=$(wg genkey); WG_PUBKEY=$(echo "$WG_PRIVKEY" | wg pubkey)
        echo ""
        success "Public key (add it on the server): ${GREEN}$WG_PUBKEY${NC}"
        read -rp "  Press Enter after adding the key on the server..."

        umask 077
        cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $WG_PRIVKEY
Address = $VPN_IP/32
DNS = $VPN_DNS
# Table=off: client routing is handled by vpn-gateway.sh (table 200),
# so wg-quick doesn't conflict with policy routing.
Table = off

[Peer]
PublicKey = $WG_SERVER_PUBKEY
$([ -n "$WG_PSK" ] && echo "PresharedKey = $WG_PSK")
Endpoint = $WG_SERVER_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0,::/0
PersistentKeepalive = 25
EOF
        umask 022
        chmod 600 /etc/wireguard/wg0.conf
        success "WireGuard configured"
        mark_done "wireguard"
    fi
fi
systemctl enable wg-quick@wg0 2>/dev/null || true

# ══════════════════════════════════════════════════════════════
# 5. MTU (deterministic: WAN MTU − 80 bytes of WireGuard overhead)
# ══════════════════════════════════════════════════════════════
header "MTU"

if is_done "mtu" && [ -n "${SAVED_MTU:-}" ]; then
    skip "MTU ($SAVED_MTU)"
    OPTIMAL_MTU="$SAVED_MTU"
else
    WAN_MTU=$(cat /sys/class/net/"$WAN_IFACE"/mtu 2>/dev/null || echo 1500)
    is_uint "$WAN_MTU" || WAN_MTU=1500
    OPTIMAL_MTU=$((WAN_MTU - 80))
    # Clamp to a sane range; can be overridden via SAVED_MTU in the config
    (( OPTIMAL_MTU < 1280 )) && OPTIMAL_MTU=1280
    (( OPTIMAL_MTU > 1420 )) && OPTIMAL_MTU=1420
    [ -n "${SAVED_MTU:-}" ] && OPTIMAL_MTU="$SAVED_MTU"
    info "WAN MTU=$WAN_MTU → tunnel MTU=$OPTIMAL_MTU (WAN − 80)"

    # Write MTU into wg0.conf
    if grep -q "^MTU" /etc/wireguard/wg0.conf 2>/dev/null; then
        sed -i "s/^MTU.*/MTU = $OPTIMAL_MTU/" /etc/wireguard/wg0.conf
    else
        sed -i "/^\[Interface\]/a MTU = $OPTIMAL_MTU" /etc/wireguard/wg0.conf
    fi
    success "Tunnel MTU: $OPTIMAL_MTU"
    mark_done "mtu"
fi

# ══════════════════════════════════════════════════════════════
# 6. SECURITY — options
# ══════════════════════════════════════════════════════════════
header "Security settings"

if is_done "security" && [ -n "${SAVED_KILL_SWITCH:-}" ]; then
    skip "security (kill_switch=$SAVED_KILL_SWITCH dns_leak=$SAVED_DNS_LEAK isolation=$SAVED_CLIENT_ISO watchdog=$SAVED_WATCHDOG)"
    KILL_SWITCH="$SAVED_KILL_SWITCH"; DNS_LEAK="$SAVED_DNS_LEAK"
    CLIENT_ISO="$SAVED_CLIENT_ISO"; WATCHDOG="$SAVED_WATCHDOG"
else
    ask "Kill switch (block internet if VPN is down)?" "${SAVED_KILL_SWITCH:-true}"
    KS=$(read_val "${SAVED_KILL_SWITCH:-true}")
    [[ "$KS" =~ ^(false|n|N) ]] && KILL_SWITCH=false || KILL_SWITCH=true

    ask "DNS leak protection?" "${SAVED_DNS_LEAK:-true}"
    DL=$(read_val "${SAVED_DNS_LEAK:-true}")
    [[ "$DL" =~ ^(false|n|N) ]] && DNS_LEAK=false || DNS_LEAK=true

    ask "Client isolation (WiFi can't see LAN)?" "${SAVED_CLIENT_ISO:-true}"
    CI=$(read_val "${SAVED_CLIENT_ISO:-true}")
    [[ "$CI" =~ ^(false|n|N) ]] && CLIENT_ISO=false || CLIENT_ISO=true

    ask "Watchdog (auto-restart VPN on failure)?" "${SAVED_WATCHDOG:-true}"
    WD=$(read_val "${SAVED_WATCHDOG:-true}")
    [[ "$WD" =~ ^(false|n|N) ]] && WATCHDOG=false || WATCHDOG=true

    success "kill_switch=$KILL_SWITCH  dns_leak=$DNS_LEAK  isolation=$CLIENT_ISO  watchdog=$WATCHDOG"
    mark_done "security"
fi

# ══════════════════════════════════════════════════════════════
# 7. TELEGRAM (optional)
# ══════════════════════════════════════════════════════════════
header "Telegram notifications (optional)"

TG_TOKEN="${SAVED_TG_TOKEN:-}"; TG_CHAT_ID="${SAVED_TG_CHAT_ID:-}"; TELEGRAM=false

if [ -n "${SAVED_TG_TOKEN:-}" ]; then
    skip "Telegram (token saved)"
    TELEGRAM=true
    ask "Change Telegram settings?" "n"; CHG=$(read_val "n")
    if [[ ! "$CHG" =~ ^[Nn] ]]; then
        TG_TOKEN=""; TG_CHAT_ID=""; TELEGRAM=false
    fi
fi

if [ "$TELEGRAM" = false ]; then
    ask "Enable Telegram notifications?" "n"; ENABLE_TG=$(read_val "n")
    if [[ ! "$ENABLE_TG" =~ ^[Nn] ]]; then
        echo ""
        info "Get a token:   @BotFather → /newbot"
        info "Get a Chat ID: message the bot, then open:"
        echo -e "    ${GRAY}https://api.telegram.org/bot<TOKEN>/getUpdates${NC}"
        echo ""
        ask "Bot token (hidden input)" ""; TG_TOKEN=$(read_secret "")
        ask "Chat ID" ""; TG_CHAT_ID=$(read_val "")
        if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            info "Testing the Telegram connection..."
            TEST=$(curl -s "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                -d chat_id="$TG_CHAT_ID" -d text="✅ VPN Gateway installed!" || true)
            if echo "$TEST" | grep -q '"ok":true'; then
                success "Telegram connected"; TELEGRAM=true
            else
                warn "Could not send a message — continuing without Telegram"
                TG_TOKEN=""; TG_CHAT_ID=""
            fi
        fi
    fi
fi

# ══════════════════════════════════════════════════════════════
# 8. WAN UPLINK (Wi-Fi connection to the router + MAC randomization)
# ══════════════════════════════════════════════════════════════
header "WAN uplink (Wi-Fi → router)"

if ! command -v nmcli >/dev/null 2>&1; then
    warn "nmcli not found — configure the WAN connection manually, skipping"
elif is_done "wan_uplink" && nmcli -t -g NAME con show 2>/dev/null | grep -qx "vpn-wan"; then
    skip "WAN uplink (SSID=$SAVED_WAN_SSID, MAC=$SAVED_WAN_MAC_MODE)"
    WAN_SSID="$SAVED_WAN_SSID"; WAN_MAC_MODE="$SAVED_WAN_MAC_MODE"
else
    ask "Set up the WAN Wi-Fi connection to the router now?" "y"
    SETUP_WAN=$(read_val "y")
    if [[ ! "$SETUP_WAN" =~ ^[Nn] ]]; then
        info "Scanning networks on $WAN_IFACE..."
        nmcli dev wifi rescan ifname "$WAN_IFACE" >/dev/null 2>&1 || true
        sleep 2
        nmcli -f SSID,SIGNAL,SECURITY dev wifi list ifname "$WAN_IFACE" 2>/dev/null | head -15 || true
        echo ""

        ask "Upstream router SSID" "${SAVED_WAN_SSID:-}"
        WAN_SSID=$(read_val "${SAVED_WAN_SSID:-}")
        [ -z "$WAN_SSID" ] && error "SSID not provided"
        ask "Password (Enter for an open network, hidden input)" ""
        WAN_PASS=$(read_secret "")

        # MAC mode: random (new on every connection) / stable (fixed per network) / keep
        info "WAN MAC mode:  random=changes every time | stable=fixed fake | keep=hardware"
        ask "MAC mode (random/stable/keep)" "${SAVED_WAN_MAC_MODE:-stable}"
        WAN_MAC_MODE=$(read_val "${SAVED_WAN_MAC_MODE:-stable}")
        case "${WAN_MAC_MODE,,}" in
            random) CLONED="random";   WAN_MAC_MODE="random" ;;
            keep|permanent|hw) CLONED="permanent"; WAN_MAC_MODE="keep" ;;
            *)      CLONED="stable";   WAN_MAC_MODE="stable" ;;
        esac

        nmcli con delete "vpn-wan" >/dev/null 2>&1 || true
        nmcli con add type wifi ifname "$WAN_IFACE" con-name "vpn-wan" ssid "$WAN_SSID" >/dev/null
        if [ -n "$WAN_PASS" ]; then
            nmcli con modify "vpn-wan" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WAN_PASS"
        fi
        nmcli con modify "vpn-wan" \
            802-11-wireless.cloned-mac-address "$CLONED" \
            connection.autoconnect yes \
            connection.autoconnect-priority 100
        if nmcli con up "vpn-wan" >/dev/null 2>&1; then
            success "WAN uplink active: SSID=$WAN_SSID  MAC=$WAN_MAC_MODE"
        else
            warn "Profile created, but couldn't connect right away — check SSID/password"
        fi
        mark_done "wan_uplink"
    else
        WAN_SSID="${SAVED_WAN_SSID:-}"; WAN_MAC_MODE="${SAVED_WAN_MAC_MODE:-keep}"
        info "Skipped — configure WAN manually"
    fi
fi

# ══════════════════════════════════════════════════════════════
# 9. NETWORKMANAGER
# ══════════════════════════════════════════════════════════════
header "NetworkManager"

if is_done "nm"; then skip "NetworkManager"
else
    # WAN (Wi-Fi client) is NOT added to unmanaged — NM manages it (keeps the uplink)
    NM_UNMANAGED="interface-name:$LAN_IFACE;interface-name:$AP_IFACE;interface-name:wg0"
    for iface in $EXTRA_ETH; do
        NM_UNMANAGED="${NM_UNMANAGED};interface-name:$iface"
    done
    NM_CONF="/etc/NetworkManager/NetworkManager.conf"
    if [ -f "$NM_CONF" ]; then
        cp "$NM_CONF" "${NM_CONF}.bak.$(date +%s)" 2>/dev/null || true
        sed -i '/\[keyfile\]/,/unmanaged-devices/d' "$NM_CONF" 2>/dev/null || true
        cat >> "$NM_CONF" << EOF

[keyfile]
unmanaged-devices=$NM_UNMANAGED
EOF
        warn "Reloading NetworkManager config (the Wi-Fi uplink may blink briefly)"
        nmcli general reload 2>/dev/null || systemctl reload NetworkManager 2>/dev/null || true
        success "NetworkManager: unmanaged=$NM_UNMANAGED"
        info "  Backup: ${NM_CONF}.bak.*"
    else
        warn "NetworkManager.conf not found — skipping"
    fi
    mark_done "nm"
fi

# ══════════════════════════════════════════════════════════════
# 10. /etc/network/interfaces
# ══════════════════════════════════════════════════════════════
header "/etc/network/interfaces"

if is_done "interfaces_cfg"; then skip "interfaces_cfg"
else
    touch /etc/network/interfaces
    cp /etc/network/interfaces /etc/network/interfaces.bak."$(date +%s)" 2>/dev/null || true
    sed -i "/auto $AP_IFACE/,+5d"  /etc/network/interfaces 2>/dev/null || true
    sed -i "/auto $LAN_IFACE/,+5d" /etc/network/interfaces 2>/dev/null || true
    for iface in $EXTRA_ETH; do
        sed -i "/auto $iface/,+5d" /etc/network/interfaces 2>/dev/null || true
    done
    cat >> /etc/network/interfaces << EOF

auto $AP_IFACE
iface $AP_IFACE inet static
    address $AP_IP
    netmask 255.255.255.0
    mtu $OPTIMAL_MTU

auto $LAN_IFACE
iface $LAN_IFACE inet static
    address $LAN_IP
    netmask 255.255.255.0
    mtu $OPTIMAL_MTU
EOF
    success "/etc/network/interfaces configured (AP + LAN)"
    info "  Backup: /etc/network/interfaces.bak.*"
    mark_done "interfaces_cfg"
fi

# ══════════════════════════════════════════════════════════════
# 11. SYSCTL
# ══════════════════════════════════════════════════════════════
header "sysctl"

if is_done "sysctl"; then skip "sysctl"
else
    SYSCTL_FILE="/etc/sysctl.d/99-vpn-gateway.conf"
    cat > "$SYSCTL_FILE" << EOF
# VPN Gateway
net.ipv4.ip_forward=1
# rp_filter loose (=2) instead of fully disabling it — required for policy
# routing, while keeping basic anti-spoofing protection
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
    sysctl --system -q >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" -q || true
    success "IP forwarding enabled, rp_filter=loose"
    mark_done "sysctl"
fi

# ══════════════════════════════════════════════════════════════
# 12. hostapd + dnsmasq
# ══════════════════════════════════════════════════════════════
header "hostapd + dnsmasq"

if is_done "apdaemon"; then skip "hostapd + dnsmasq"
else
    # hostapd
    umask 077
    cat > /etc/hostapd/hostapd.conf << EOF
interface=$AP_IFACE
driver=nl80211
ssid=$SSID
hw_mode=$HW_MODE
channel=$CHANNEL
$([ -n "$AP_MAC" ] && echo "bssid=$AP_MAC")
wpa=2
wpa_passphrase=$WIFI_PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ctrl_interface=/var/run/hostapd
notify_mgmt_frames=0
EOF
    umask 022
    chmod 600 /etc/hostapd/hostapd.conf
    systemctl unmask hostapd 2>/dev/null || true
    systemctl enable hostapd
    success "hostapd configured (SSID=$SSID)"

    # systemd-resolved may hold :53 — disable its stub listener
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/vpn-gateway.conf << EOF
[Resolve]
DNSStubListener=no
EOF
        systemctl restart systemd-resolved 2>/dev/null || true
        info "systemd-resolved: stub listener on :53 disabled (freed for dnsmasq)"
    fi

    # dnsmasq
    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak."$(date +%s)" 2>/dev/null || true
    sed -i '/# VPN Gateway/,$ d' /etc/dnsmasq.conf 2>/dev/null || true
    cat >> /etc/dnsmasq.conf << EOF

# VPN Gateway
# bind-dynamic: dnsmasq won't crash if the interface has no IP yet, and won't grab :53 everywhere
bind-dynamic
interface=$AP_IFACE
interface=$LAN_IFACE
dhcp-range=$AP_IFACE,${AP_NET}.10,${AP_NET}.100,255.255.255.0,12h
dhcp-range=$LAN_IFACE,${LAN_NET}.10,${LAN_NET}.50,255.255.255.0,12h
no-resolv
server=$VPN_DNS
dhcp-option=$AP_IFACE,6,$VPN_DNS
dhcp-option=$LAN_IFACE,6,$VPN_DNS
dhcp-option=26,$OPTIMAL_MTU
EOF
    systemctl enable dnsmasq
    success "dnsmasq configured (DNS=$VPN_DNS MTU=$OPTIMAL_MTU)"
    mark_done "apdaemon"
fi

# ══════════════════════════════════════════════════════════════
# 13. TELEGRAM SCRIPT
# ══════════════════════════════════════════════════════════════
header "Telegram script"

umask 077
cat > /usr/local/bin/vpn-tg.sh << EOF
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
AP_IFACE="$AP_IFACE"
HOST="\$(hostname)"

tg() {
    [ -z "\$TG_TOKEN" ] && return
    curl -s -X POST "https://api.telegram.org/bot\${TG_TOKEN}/sendMessage" \
        -d chat_id="\$TG_CHAT_ID" -d parse_mode="HTML" -d text="\$1" >/dev/null 2>&1 || true
}

case "\$1" in
    vpn_up)
        EXT=\$(curl -s --interface wg0 ifconfig.me 2>/dev/null || echo "—")
        tg "✅ <b>VPN connected</b>
🖥 \$HOST | 🌐 \$EXT
🕐 \$(date '+%d.%m %H:%M')"
        ;;
    vpn_down)
        tg "❌ <b>VPN down!</b>
🖥 \$HOST | ⚠️ Kill switch active
🕐 \$(date '+%d.%m %H:%M')"
        ;;
    vpn_restored)
        tg "🔄 <b>VPN restored</b>
🖥 \$HOST
🕐 \$(date '+%d.%m %H:%M')"
        ;;
    client_connected)
        tg "📱 <b>Client connected</b>
📡 \$2 | 🌐 \$3 | 💻 \$4
🕐 \$(date '+%d.%m %H:%M')"
        ;;
    client_disconnected)
        tg "👋 <b>Client disconnected</b>
📡 \$2
🕐 \$(date '+%d.%m %H:%M')"
        ;;
    daily_stats)
        ST=\$(ip link show wg0 &>/dev/null && echo "✅" || echo "❌")
        TR=\$(wg show wg0 2>/dev/null | grep transfer | awk '{print \$2,\$3,\$4,\$5}')
        CL=\$(iw dev "\$AP_IFACE" station dump 2>/dev/null | grep -c "Station" || echo 0)
        EXT=\$(curl -s --interface wg0 ifconfig.me 2>/dev/null || echo "—")
        tg "📊 <b>Statistics</b>
🖥 \$HOST | VPN: \$ST | 🌐 \$EXT
📶 WiFi: \$CL clients
📈 \$TR
🕐 \$(date '+%d.%m %H:%M')"
        ;;
esac
EOF
umask 022
chmod 700 /usr/local/bin/vpn-tg.sh   # secret inside → root only
success "vpn-tg.sh installed (chmod 700)"

# ══════════════════════════════════════════════════════════════
# 14. MAIN SCRIPT vpn-gateway.sh
# ══════════════════════════════════════════════════════════════
header "vpn-gateway.sh"

cat > /usr/local/bin/vpn-gateway.sh << EOF
#!/bin/bash
# ── VPN Gateway ──────────────────────────────────────────
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

WAN="$WAN_IFACE"
AP="$AP_IFACE"
LAN="$LAN_IFACE"
VPN="wg0"
AP_IP="$AP_IP"
LAN_IP="$LAN_IP"
VPN_IP="$VPN_IP"
AP_NET="${AP_NET}.0/24"
LAN_NET="${LAN_NET}.0/24"
MTU="$OPTIMAL_MTU"
KILL_SWITCH="$KILL_SWITCH"
DNS_LEAK="$DNS_LEAK"
CLIENT_ISO="$CLIENT_ISO"
EXTRA_ETH="$EXTRA_ETH"
AP_MAC="$AP_MAC"
AP_MAC_RANDOM="$AP_MAC_RANDOM"

LOG="/var/log/vpn-gateway.log"
mkdir -p "\$(dirname \$LOG)"
exec >> "\$LOG" 2>&1
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1"; }

log "════ VPN Gateway start ════"

# ── iptables helpers: work ONLY in our own chains ──
ensure_chain() { # <table> <chain>
    iptables -t "\$1" -nL "\$2" &>/dev/null || iptables -t "\$1" -N "\$2"
    iptables -t "\$1" -F "\$2"
}
ensure_jump() {  # <table> <parent> <our_chain>
    iptables -t "\$1" -C "\$2" -j "\$3" 2>/dev/null || iptables -t "\$1" -I "\$2" -j "\$3"
}

# ── Bring down extra ETH ──
for iface in \$EXTRA_ETH; do
    ip link set "\$iface" down 2>/dev/null && log "Brought down: \$iface" || true
done

# ── Interfaces and MTU (up before VPN so the kill switch is ready) ──
# Apply the randomized BSSID (interface must be down)
if [ "\$AP_MAC_RANDOM" = "true" ] && [ -n "\$AP_MAC" ]; then
    ip link set "\$AP" down 2>/dev/null || true
    ip link set "\$AP" address "\$AP_MAC" 2>/dev/null \
        && log "AP MAC = \$AP_MAC" \
        || log "Failed to set AP MAC"
fi
ip link set "\$LAN" up 2>/dev/null || true
ip link set "\$AP"  up 2>/dev/null || true
sleep 1
ip link set "\$LAN" mtu "\$MTU" 2>/dev/null || true
ip link set "\$AP"  mtu "\$MTU" 2>/dev/null || true
ip addr add "\$LAN_IP/24" dev "\$LAN" 2>/dev/null || true
ip addr add "\$AP_IP/24"  dev "\$AP"  2>/dev/null || true

# ── sysctl (on the fly) ──
sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv4.conf.all.rp_filter=2
sysctl -qw "net.ipv4.conf.\$AP.rp_filter=2"  2>/dev/null || true
sysctl -qw "net.ipv4.conf.\$LAN.rp_filter=2" 2>/dev/null || true
sysctl -qw "net.ipv4.conf.\$VPN.rp_filter=2" 2>/dev/null || true

# ── iptables (in dedicated chains, other rules untouched) ──
ensure_chain filter VPNGW_FWD
ensure_jump  filter FORWARD VPNGW_FWD
ensure_chain nat    VPNGW_POST
ensure_jump  nat    POSTROUTING VPNGW_POST
ensure_chain nat    VPNGW_PRE
ensure_jump  nat    PREROUTING VPNGW_PRE
ensure_chain mangle VPNGW_MANGLE
ensure_jump  mangle FORWARD VPNGW_MANGLE

# MSS clamping — TCP MTU fix
iptables -t mangle -A VPNGW_MANGLE -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss \$((MTU - 40))

# NAT clients into the tunnel
iptables -t nat -A VPNGW_POST -s "\$AP_NET"  -o "\$VPN" -j MASQUERADE
iptables -t nat -A VPNGW_POST -s "\$LAN_NET" -o "\$VPN" -j MASQUERADE

# DNS leak protection — redirect :53 to the local dnsmasq
if [ "\$DNS_LEAK" = "true" ]; then
    iptables -t nat -A VPNGW_PRE -i "\$AP"  -p udp --dport 53 -j DNAT --to "\$AP_IP:53"
    iptables -t nat -A VPNGW_PRE -i "\$LAN" -p udp --dport 53 -j DNAT --to "\$LAN_IP:53"
    iptables -t nat -A VPNGW_PRE -i "\$AP"  -p tcp --dport 53 -j DNAT --to "\$AP_IP:53"
    iptables -t nat -A VPNGW_PRE -i "\$LAN" -p tcp --dport 53 -j DNAT --to "\$LAN_IP:53"
    log "DNS leak protection active"
fi

# Client isolation (before the accepts)
if [ "\$CLIENT_ISO" = "true" ]; then
    iptables -A VPNGW_FWD -i "\$AP"  -o "\$LAN" -j DROP
    iptables -A VPNGW_FWD -i "\$LAN" -o "\$AP"  -j DROP
    log "Client isolation active"
fi

# Kill switch: clients can't reach WAN directly (fail-closed, even if VPN is down)
if [ "\$KILL_SWITCH" = "true" ]; then
    iptables -A VPNGW_FWD -i "\$AP"  -o "\$WAN" -j DROP
    iptables -A VPNGW_FWD -i "\$LAN" -o "\$WAN" -j DROP
    log "Kill switch active"
fi

# Allowed client <-> VPN flows
iptables -A VPNGW_FWD -i "\$AP"  -o "\$VPN" -j ACCEPT
iptables -A VPNGW_FWD -i "\$LAN" -o "\$VPN" -j ACCEPT
iptables -A VPNGW_FWD -i "\$VPN" -o "\$AP"  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A VPNGW_FWD -i "\$VPN" -o "\$LAN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ── VPN ──
if ! ip link show "\$VPN" &>/dev/null; then
    log "Bringing up WireGuard..."
    wg-quick up wg0 \
        && /usr/local/bin/vpn-tg.sh vpn_up \
        || { /usr/local/bin/vpn-tg.sh vpn_down; log "WireGuard failed to come up!"; }
else
    log "WireGuard already running"
fi

# Wait for wg0 to actually come up (up to 20s)
for i in \$(seq 1 10); do
    ip link show "\$VPN" &>/dev/null && break
    log "Waiting for \$VPN... (\$i/10)"
    sleep 2
done

if ! ip link show "\$VPN" &>/dev/null; then
    log "ERROR: \$VPN did not come up — not building routes. Kill switch holds fail-closed."
    # Exit successfully: firewall is already applied (kill switch holds), watchdog will retry.
    exit 0
fi

# ── Routing (policy routing via table 200) ──
ip rule del from "\$AP_NET"  lookup 200 2>/dev/null || true
ip rule del from "\$LAN_NET" lookup 200 2>/dev/null || true
ip rule add from "\$AP_NET"  lookup 200 priority 100
ip rule add from "\$LAN_NET" lookup 200 priority 100

ip route flush table 200 2>/dev/null || true
ip route add default     dev "\$VPN" table 200
ip route add "\$AP_NET"  dev "\$AP"  table 200
ip route add "\$LAN_NET" dev "\$LAN" table 200

ip route replace "\$LAN_NET" dev "\$LAN" src "\$LAN_IP"
ip route replace "\$AP_NET"  dev "\$AP"  src "\$AP_IP" 2>/dev/null || true

# Flush conntrack ONLY for the client networks (leave other connections alone)
conntrack -D -s "\$AP_NET"  2>/dev/null || true
conntrack -D -s "\$LAN_NET" 2>/dev/null || true

# ── Services ──
systemctl restart hostapd
sleep 1
systemctl restart dnsmasq

log "════ Done: WiFi=$SSID AP=\$AP_IP LAN=\$LAN_IP VPN=\$VPN_IP MTU=\$MTU ════"
EOF
chmod +x /usr/local/bin/vpn-gateway.sh
success "vpn-gateway.sh installed"

# ══════════════════════════════════════════════════════════════
# 15. WATCHDOG + hostapd notification hook
# ══════════════════════════════════════════════════════════════
header "Watchdog"

if is_done "watchdog_script"; then skip "watchdog"
else
    cat > /usr/local/bin/vpn-watchdog.sh << 'EOF'
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LOG="/var/log/vpn-watchdog.log"
LOCK="/run/vpn-watchdog.lock"
STAMP="/run/vpn-daily.stamp"

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

# Lock with stale protection (5 minutes)
if [ -f "$LOCK" ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
    [ "$AGE" -lt 300 ] && exit 0
    log "Stale lock ($AGE s) — removing"
fi
echo "$$" > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

WG_HANDSHAKE=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
NOW=$(date +%s)
AGE=$(( NOW - ${WG_HANDSHAKE:-0} ))

if ! ip link show wg0 &>/dev/null || [ "${WG_HANDSHAKE:-0}" = "0" ] || [ "$AGE" -gt 180 ]; then
    log "VPN unreachable — restarting..."
    /usr/local/bin/vpn-tg.sh vpn_down
    wg-quick down wg0 2>/dev/null || true
    sleep 2
    wg-quick up wg0 || log "wg-quick up failed"
    sleep 5
    /usr/local/bin/vpn-gateway.sh
    /usr/local/bin/vpn-tg.sh vpn_restored
    log "Recovery complete"
else
    # Daily stats — exactly once per day
    if [ "$(date +%H%M)" = "0900" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" != "$(date +%F)" ]; then
        date +%F > "$STAMP"
        /usr/local/bin/vpn-tg.sh daily_stats
    fi
fi
EOF
    chmod +x /usr/local/bin/vpn-watchdog.sh

    if [ "$WATCHDOG" = "true" ]; then
        CRON_TMP=$(mktemp)
        crontab -l 2>/dev/null | grep -v vpn-watchdog > "$CRON_TMP" || true
        echo "* * * * * /usr/local/bin/vpn-watchdog.sh" >> "$CRON_TMP"
        echo "* * * * * sleep 30 && /usr/local/bin/vpn-watchdog.sh" >> "$CRON_TMP"
        crontab "$CRON_TMP"
        rm -f "$CRON_TMP"
        success "Watchdog installed (every 30s)"
    else
        success "vpn-watchdog.sh installed (cron disabled)"
    fi

    # hostapd hook for notifications
    cat > /etc/hostapd/hostapd-action.sh << 'EOF'
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
IFACE="$1"; EVENT="$2"; MAC="$3"
case "$EVENT" in
    AP-STA-CONNECTED)
        sleep 2
        IP=$(grep -i "$MAC" /var/lib/misc/dnsmasq.leases 2>/dev/null | awk '{print $3}')
        NAME=$(grep -i "$MAC" /var/lib/misc/dnsmasq.leases 2>/dev/null | awk '{print $4}')
        /usr/local/bin/vpn-tg.sh client_connected "$MAC" "$IP" "$NAME"
        ;;
    AP-STA-DISCONNECTED)
        /usr/local/bin/vpn-tg.sh client_disconnected "$MAC"
        ;;
esac
EOF
    chmod +x /etc/hostapd/hostapd-action.sh

    # NOTE: hostapd doesn't call action scripts itself. hostapd_cli -a is required.
    HOSTAPD_CLI="$(command -v hostapd_cli || echo /usr/sbin/hostapd_cli)"
    cat > /etc/systemd/system/vpn-hostapd-notify.service << EOF
[Unit]
Description=hostapd client notifier (Telegram)
After=hostapd.service
BindsTo=hostapd.service

[Service]
ExecStart=$HOSTAPD_CLI -i $AP_IFACE -a /etc/hostapd/hostapd-action.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable vpn-hostapd-notify 2>/dev/null || true
    success "hostapd_cli action service installed (client notifications active)"

    mark_done "watchdog_script"
fi

# ══════════════════════════════════════════════════════════════
# 16. SYSTEMD SERVICE
# ══════════════════════════════════════════════════════════════
header "Systemd service"

if is_done "service"; then skip "systemd service"
else
    cat > /etc/systemd/system/vpn-gateway.service << EOF
[Unit]
Description=VPN Gateway
After=network-online.target wg-quick@wg0.service NetworkManager.service
Wants=network-online.target
Requires=wg-quick@wg0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/vpn-gateway.sh

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable vpn-gateway
    success "vpn-gateway service installed"
    mark_done "service"
fi

# ══════════════════════════════════════════════════════════════
# SAVE CONFIG
# ══════════════════════════════════════════════════════════════
umask 077
cat > "$CONFIG_FILE" << EOF
# VPN Gateway config — $(date)
SAVED_WAN="$WAN_IFACE"
SAVED_AP="$AP_IFACE"
SAVED_LAN="$LAN_IFACE"
SAVED_AP_MAC="$AP_MAC"
SAVED_EXTRA_ETH="$EXTRA_ETH"
SAVED_SSID="$SSID"
SAVED_WIFI_PASS="$WIFI_PASS"
SAVED_AP_IP="$AP_IP"
SAVED_LAN_IP="$LAN_IP"
SAVED_VPN_IP="$VPN_IP"
SAVED_VPN_DNS="$VPN_DNS"
SAVED_MTU="$OPTIMAL_MTU"
SAVED_HW_MODE="$HW_MODE"
SAVED_CHANNEL="$CHANNEL"
SAVED_KILL_SWITCH="$KILL_SWITCH"
SAVED_DNS_LEAK="$DNS_LEAK"
SAVED_CLIENT_ISO="$CLIENT_ISO"
SAVED_WATCHDOG="$WATCHDOG"
SAVED_TG_TOKEN="$TG_TOKEN"
SAVED_TG_CHAT_ID="$TG_CHAT_ID"
SAVED_AP_MAC_RANDOM="$AP_MAC_RANDOM"
SAVED_WAN_SSID="$WAN_SSID"
SAVED_WAN_MAC_MODE="$WAN_MAC_MODE"
EOF
umask 022
chmod 600 "$CONFIG_FILE"

# ══════════════════════════════════════════════════════════════
# VERIFICATION
# ══════════════════════════════════════════════════════════════
header "Installation check"

echo ""
info "WireGuard:"
if ip link show wg0 &>/dev/null; then
    success "wg0 is up"
else
    warn "wg0 not active (will come up via the service after reboot)"
fi

echo ""
info "hostapd:"
if systemctl is-active --quiet hostapd; then
    success "hostapd running (SSID=$SSID)"
else
    warn "hostapd not running (will come up via the service)"
fi

echo ""
info "dnsmasq:"
if systemctl is-active --quiet dnsmasq; then
    success "dnsmasq running"
else
    warn "dnsmasq not running (will come up via the service)"
fi

echo ""
info "NetworkManager (unmanaged):"
if grep -q "unmanaged-devices" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
    success "unmanaged-devices configured"
else
    warn "unmanaged-devices not configured"
fi

echo ""
info "Component status:"
for c in $COMPONENTS; do
    is_done "$c" \
        && echo -e "    ${GREEN}[✓]${NC} $c" \
        || echo -e "    ${RED}[ ]${NC} $c"
done

# ══════════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║      Installation complete!              ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  WiFi      : ${GREEN}$SSID${NC} / ${GRAY}(password hidden)${NC}"
echo -e "  AP IP     : ${GREEN}$AP_IP${NC}"
echo -e "  LAN IP    : ${GREEN}$LAN_IP${NC}"
echo -e "  MTU       : ${GREEN}$OPTIMAL_MTU${NC}"
echo -e "  WAN uplink: $([ -n "$WAN_SSID" ] && echo "${GREEN}$WAN_SSID${NC}" || echo "${GRAY}manual${NC}") ${GRAY}(MAC: $WAN_MAC_MODE)${NC}"
echo -e "  AP BSSID  : $([ "$AP_MAC_RANDOM" = true ] && echo "${GREEN}random ($AP_MAC)${NC}" || echo "${GRAY}hardware${NC}")"
echo -e "  Telegram  : $([ "$TELEGRAM" = true ] && echo "${GREEN}enabled${NC}" || echo "${GRAY}disabled${NC}")"
echo ""
echo -e "  Re-run            : ${CYAN}sudo $0${NC}"
echo -e "  Installer logs    : ${CYAN}$LOG_FILE${NC}"
echo -e "  Gateway logs      : ${CYAN}/var/log/vpn-gateway.log${NC}"
echo -e "  Watchdog logs     : ${CYAN}/var/log/vpn-watchdog.log${NC}"
echo -e "  Component status  : ${CYAN}cat $STATE_FILE${NC}"
echo -e "  Config            : ${CYAN}$CONFIG_FILE${NC}"
echo ""
echo "════ Finished: $(date '+%Y-%m-%d %H:%M:%S') ════"

if [ "$TELEGRAM" = true ]; then
    /usr/local/bin/vpn-tg.sh vpn_up || true
fi

read -rp "  Reboot now? (y/n): " _REBOOT
[ "$_REBOOT" = "y" ] && reboot
exit 0
