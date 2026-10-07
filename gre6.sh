#!/usr/bin/env bash
# ============================================================
#  GRE6 Tunnel Manager
#  Transport : GRE over IPv4  (both servers only need a public IPv4)
#  Inside    : IPv6 only, addresses derived from the IPv4 (6to4 style)
#                 140.233.177.59 -> 2002:8ce9:b13b::1
#  Iran side : enter the info once, get a HASH CODE
#  Foreign   : paste the hash code, done
# ============================================================
set -u

APP="gre6"
# Raw URL of this script on GitHub (used when started via a link)
SCRIPT_URL="https://raw.githubusercontent.com/imahdavii/gre6-tunnel/main/gre6.sh"
CONF_DIR="${GRE6_CONF_DIR:-/etc/gre6tunnel}"
BIN="/usr/local/bin/gre6"
SYSTEMD_DIR="/etc/systemd/system"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
ok()   { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[-]${N} $*"; }
info() { echo -e "${C}[*]${N} $*"; }

need_root() { [ "$(id -u)" -eq 0 ] || { err "Run as root."; exit 1; }; }

# ---------------------------------------------------------- deps
install_py() {
  python3 -c 'import colorama, netifaces' 2>/dev/null && return 0
  info "Installing python3, pip, colorama, netifaces..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    apt-get install -y python3 python3-pip python3-colorama python3-netifaces >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 python3-pip python3-colorama python3-netifaces >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 python3-pip >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add python3 py3-pip py3-colorama >/dev/null 2>&1
  fi
  python3 -c 'import colorama, netifaces' 2>/dev/null && return 0
  python3 -m pip install colorama netifaces >/dev/null 2>&1 \
    || python3 -m pip install --break-system-packages colorama netifaces >/dev/null 2>&1 \
    || warn "colorama/netifaces could not be installed (this script itself does not need them)."
  return 0
}

install_deps() {
  local missing=0 c
  for c in ip iptables ip6tables curl openssl sha256sum base64 ping systemctl; do
    command -v "$c" >/dev/null 2>&1 || missing=1
  done
  if [ "$missing" -eq 1 ] || [ "${1:-}" = "force" ]; then
    info "Installing prerequisites..."
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1
      apt-get install -y iproute2 iptables curl openssl coreutils iputils-ping
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y iproute iptables curl openssl coreutils iputils
    elif command -v yum >/dev/null 2>&1; then
      yum install -y iproute iptables curl openssl coreutils iputils
    elif command -v apk >/dev/null 2>&1; then
      apk add iproute2 iptables ip6tables curl openssl coreutils iputils
    else
      warn "Unknown package manager. Install manually: iproute2 iptables curl openssl"
    fi
  fi
  install_py
  modprobe ip_gre 2>/dev/null || true
  ok "Prerequisites checked."
}

self_install() {
  # copy this script to /usr/local/bin/gre6 so the menu is always available as: gre6
  local me
  me="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  if [ "$me" != "$BIN" ]; then
    if [ -f "$0" ] && [ -r "$0" ]; then
      cat "$0" > "$BIN" && chmod +x "$BIN"
    elif [[ "$SCRIPT_URL" == https://* && "$SCRIPT_URL" != *YOUR_USER* ]]; then
      # started from a link (bash <(curl ...)): download a clean copy
      if curl -fsSL "$SCRIPT_URL" -o "$BIN.tmp" && bash -n "$BIN.tmp" 2>/dev/null; then
        mv "$BIN.tmp" "$BIN"; chmod +x "$BIN"
      else
        rm -f "$BIN.tmp"; warn "Could not download $SCRIPT_URL"
      fi
    else
      warn "Set SCRIPT_URL at the top of the script, or run it from a saved file."
    fi
  fi
  [ -x "$BIN" ] || { err "$BIN is missing; the tunnel service needs it."; return 1; }
  write_units
}

write_units() {
  cat > "$SYSTEMD_DIR/gre6@.service" <<EOF
[Unit]
Description=GRE6 tunnel %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN up %i
ExecStop=$BIN down %i

[Install]
WantedBy=multi-user.target
EOF
  cat > "$SYSTEMD_DIR/gre6-watch@.service" <<EOF
[Unit]
Description=GRE6 ping watchdog %i

[Service]
Type=oneshot
ExecStart=$BIN watch %i
EOF
  cat > "$SYSTEMD_DIR/gre6-watch@.timer" <<EOF
[Unit]
Description=GRE6 ping watchdog timer %i

[Timer]
OnBootSec=90
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

# ---------------------------------------------------------- helpers
valid_v4() {
  local ip=$1 o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -ra oct <<< "$ip"
  for o in "${oct[@]}"; do [ "$((10#$o))" -le 255 ] || return 1; done
  return 0
}
valid_name()  { [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]]; }
valid_extra() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -le 50 ]; }
valid_mtu()   { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1280 ] && [ "$1" -le 1476 ]; }

# 140.233.177.59 -> 2002:8ce9:b13b   (prefix; "::N" is appended by the caller)
hex6() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  printf '2002:%02x%02x:%02x%02x' "$((10#$a))" "$((10#$b))" "$((10#$c))" "$((10#$d))"
}

detect_v4() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

list_tunnels() {
  local f
  for f in "$CONF_DIR"/*.conf; do
    [ -e "$f" ] && basename "$f" .conf
  done
}

SEL=""
pick_tunnel() {
  local t=() x n i=1
  while IFS= read -r x; do t+=("$x"); done < <(list_tunnels)
  if [ ${#t[@]} -eq 0 ]; then warn "No tunnel configured yet."; return 1; fi
  if [ ${#t[@]} -eq 1 ]; then SEL="${t[0]}"; return 0; fi
  for x in "${t[@]}"; do echo "  $i) $x"; i=$((i+1)); done
  read -rp "Select tunnel number: " n
  if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#t[@]} ]; then
    SEL="${t[$((n-1))]}"; return 0
  fi
  err "Invalid choice."; return 1
}

load_conf() {
  local f="$CONF_DIR/$1.conf"
  [ -f "$f" ] || { err "Config $1 not found."; return 1; }
  # shellcheck disable=SC1090
  . "$f"
}

make_conf() { # role name iran4 foreign4 extra mtu
  local role=$1 name=$2 ir4=$3 kh4=$4 extra=$5 mtu=$6
  local l4 r4 lp rp
  if [ "$role" = "iran" ]; then l4=$ir4; r4=$kh4; else l4=$kh4; r4=$ir4; fi
  lp="$(hex6 "$l4")"; rp="$(hex6 "$r4")"
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
  cat > "$CONF_DIR/$name.conf" <<EOF
NAME="$name"
ROLE="$role"
IRAN4="$ir4"
FOREIGN4="$kh4"
EXTRA="$extra"
MTU="$mtu"
LOCAL4="$l4"
REMOTE4="$r4"
LPFX="$lp"
RPFX="$rp"
LIP6="$lp::1"
RIP6="$rp::1"
EOF
  chmod 600 "$CONF_DIR/$name.conf"
}

# ---------------------------------------------------------- hash code
# payload:  v2;name;iran4;foreign4;extra;mtu   + ";" + first 8 hex of sha256
encode_code() { # name iran4 foreign4 extra mtu
  local p="v2;$1;$2;$3;$4;$5" sum
  sum=$(printf '%s' "$p" | sha256sum | cut -c1-8)
  printf '%s;%s' "$p" "$sum" | base64 -w0 | tr '+/' '-_' | tr -d '=' | sed 's/^/GRE6-/'
}

DEC_NAME=""; DEC_IR4=""; DEC_KH4=""; DEC_EXTRA=""; DEC_MTU=""
decode_code() {
  local c="${1#GRE6-}" raw p sum ver
  c=$(printf '%s' "$c" | tr -d ' \r\n' | tr '_-' '/+')
  while [ $(( ${#c} % 4 )) -ne 0 ]; do c="${c}="; done
  raw=$(printf '%s' "$c" | base64 -d 2>/dev/null) || return 1
  sum="${raw##*;}"; p="${raw%;*}"
  [ "$(printf '%s' "$p" | sha256sum | cut -c1-8)" = "$sum" ] || return 1
  IFS=';' read -r ver DEC_NAME DEC_IR4 DEC_KH4 DEC_EXTRA DEC_MTU <<< "$p"
  [ "$ver" = "v2" ] || return 1
  valid_name "$DEC_NAME" && valid_v4 "$DEC_IR4" && valid_v4 "$DEC_KH4" \
    && valid_extra "$DEC_EXTRA" && valid_mtu "$DEC_MTU"
}

# ---------------------------------------------------------- tunnel up/down
tunnel_down() {
  load_conf "$1" || return 1
  ip link set "$NAME" down 2>/dev/null
  ip tunnel del "$NAME" 2>/dev/null
  iptables -D INPUT -p gre -s "$REMOTE4" -j ACCEPT 2>/dev/null
  ip6tables -D INPUT -i "$NAME" -j ACCEPT 2>/dev/null
  return 0
}

tunnel_up() {
  load_conf "$1" || return 1
  local i
  modprobe ip_gre 2>/dev/null || true
  if ip link show "$NAME" >/dev/null 2>&1; then
    ip link set "$NAME" down 2>/dev/null; ip tunnel del "$NAME" 2>/dev/null
  fi
  if ! ip tunnel add "$NAME" mode gre local "$LOCAL4" remote "$REMOTE4" ttl 255; then
    err "Failed to create the GRE tunnel (is $LOCAL4 an address of this server? is ip_gre available?)."
    return 1
  fi
  ip link set "$NAME" mtu "$MTU"
  # IPv6 must not be disabled on this host
  if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" = "1" ]; then
    warn "IPv6 was disabled on this server; enabling it."
    sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0
  fi
  sysctl -qw "net.ipv6.conf.$NAME.disable_ipv6=0" 2>/dev/null
  ip link set "$NAME" up
  ip -6 addr add "$LIP6/64" dev "$NAME" nodad
  for ((i=2; i<=EXTRA+1; i++)); do
    ip -6 addr add "$LPFX::$i/64" dev "$NAME" nodad
  done
  ip -6 route replace "$RPFX::/64" dev "$NAME"
  # let GRE (protocol 47) and tunnel traffic through the local firewall
  iptables -C INPUT -p gre -s "$REMOTE4" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p gre -s "$REMOTE4" -j ACCEPT 2>/dev/null
  ip6tables -C INPUT -i "$NAME" -j ACCEPT 2>/dev/null \
    || ip6tables -I INPUT -i "$NAME" -j ACCEPT 2>/dev/null
  return 0
}

tunnel_watch() {
  load_conf "$1" || return 1
  if ! ping -6 -c3 -W2 "$RIP6" >/dev/null 2>&1; then
    logger -t gre6 "tunnel $NAME: no reply from $RIP6, restarting"
    systemctl restart "gre6@$NAME.service"
  fi
}

enable_service() { systemctl enable --now "gre6@$1.service" >/dev/null 2>&1; }
enable_watch()   { systemctl enable --now "gre6-watch@$1.timer" >/dev/null 2>&1; }

# ---------------------------------------------------------- menu actions
ask() { # prompt default -> REPLY
  local d="${2:-}" a
  if [ -n "$d" ]; then read -rp "$1 [$d]: " a; REPLY="${a:-$d}"; else read -rp "$1: " a; REPLY="$a"; fi
}

show_addrs() { # after load_conf
  info "Your IPv6   : ${G}$LIP6${N}$( [ "$EXTRA" -gt 0 ] && echo "  (+$EXTRA extra: $LPFX::2 ...)" )"
  info "Peer IPv6   : ${G}$RIP6${N}"
}

setup_iran() {
  echo; info "=== IRAN server setup ==="
  local name ir4 kh4 extra mtu
  ask "Tunnel name (letters/digits, max 15)" "gre6a"; name="$REPLY"
  valid_name "$name" || { err "Bad name."; return; }
  [ -f "$CONF_DIR/$name.conf" ] && { err "Tunnel $name already exists. Remove it first."; return; }
  ask "IRAN IPv4 address (this server)" "$(detect_v4)"; ir4="$REPLY"
  valid_v4 "$ir4" || { err "Invalid IPv4."; return; }
  ask "KHAREJ IPv4 address" ""; kh4="$REPLY"
  valid_v4 "$kh4" || { err "Invalid IPv4."; return; }
  [ "$ir4" != "$kh4" ] || { err "The two IPv4 addresses must differ."; return; }
  ask "Number of additional IPv6 addresses" "1"; extra="$REPLY"
  valid_extra "$extra" || { err "Enter a number from 0 to 50."; return; }
  ask "MTU (1280-1476)" "1400"; mtu="$REPLY"
  valid_mtu "$mtu" || { err "Bad MTU."; return; }

  make_conf iran "$name" "$ir4" "$kh4" "$extra" "$mtu"
  self_install || { rm -f "$CONF_DIR/$name.conf"; return; }
  tunnel_up "$name" || return
  enable_service "$name"
  read -rp "Enable ping keepalive / auto-restart (recommended)? [Y/n]: " w
  [[ "$w" =~ ^[Nn]$ ]] || { enable_watch "$name"; ok "Keepalive enabled."; }
  load_conf "$name"
  ok "Iran side is up."
  show_addrs
  echo
  echo -e "${Y}Copy this HASH CODE and use option 2 on the KHAREJ server:${N}"
  echo
  encode_code "$name" "$ir4" "$kh4" "$extra" "$mtu"; echo; echo
}

setup_foreign() {
  echo; info "=== KHAREJ (foreign) server setup ==="
  read -rp "Paste hash code: " code
  if ! decode_code "$code"; then err "Invalid or corrupted hash code."; return; fi
  [ -f "$CONF_DIR/$DEC_NAME.conf" ] && { err "Tunnel $DEC_NAME already exists here. Remove it first."; return; }
  info "Tunnel: $DEC_NAME | Iran: $DEC_IR4 | Kharej: $DEC_KH4 | extra IPv6: $DEC_EXTRA | MTU: $DEC_MTU"
  local mine; mine="$(detect_v4)"
  if [ -n "$mine" ] && [ "$mine" != "$DEC_KH4" ]; then
    warn "This server's IPv4 ($mine) differs from the Kharej IPv4 in the code ($DEC_KH4)."
    read -rp "Continue anyway? [y/N]: " y; [[ "$y" =~ ^[Yy]$ ]] || return
  fi
  make_conf foreign "$DEC_NAME" "$DEC_IR4" "$DEC_KH4" "$DEC_EXTRA" "$DEC_MTU"
  self_install || { rm -f "$CONF_DIR/$DEC_NAME.conf"; return; }
  tunnel_up "$DEC_NAME" || return
  enable_service "$DEC_NAME"
  read -rp "Enable ping keepalive / auto-restart (recommended)? [Y/n]: " w
  [[ "$w" =~ ^[Nn]$ ]] || { enable_watch "$DEC_NAME"; ok "Keepalive enabled."; }
  load_conf "$DEC_NAME"
  ok "Kharej side is up."
  show_addrs
  echo; info "Ping $RIP6 ..."
  if ping -6 -c3 -W2 "$RIP6"; then ok "Tunnel is working."
  else warn "No reply yet. Make sure the Iran side is up and GRE (protocol 47) is allowed by both firewalls."; fi
}

show_code() {
  pick_tunnel || return
  load_conf "$SEL" || return
  echo; echo -e "${Y}Hash code for $SEL:${N}"
  encode_code "$NAME" "$IRAN4" "$FOREIGN4" "$EXTRA" "$MTU"; echo; echo
}

show_status() {
  pick_tunnel || return
  load_conf "$SEL" || return
  echo
  ip -d addr show "$NAME" 2>/dev/null || warn "Interface $NAME not present."
  echo
  info "Role: $ROLE | local IPv4: $LOCAL4 | remote IPv4: $REMOTE4 | MTU: $MTU"
  show_addrs
  echo; info "Ping $RIP6 ..."
  ping -6 -c4 -W2 "$RIP6" && ok "Tunnel is working." || err "No reply from the other side."
}

watchdog() {
  pick_tunnel || return
  echo "  1) Enable ping keepalive / auto-restart"
  echo "  2) Disable"
  read -rp "Choice: " c
  write_units
  case "$c" in
    1) enable_watch "$SEL" && ok "Enabled." ;;
    2) systemctl disable --now "gre6-watch@$SEL.timer" >/dev/null 2>&1 && ok "Disabled." ;;
    *) err "Invalid." ;;
  esac
}

restart_tunnel() {
  pick_tunnel || return
  tunnel_up "$SEL" && ok "Tunnel $SEL restarted."
}

remove_tunnel() {
  pick_tunnel || return
  read -rp "Remove tunnel $SEL? [y/N]: " y; [[ "$y" =~ ^[Yy]$ ]] || return
  systemctl disable --now "gre6-watch@$SEL.timer" >/dev/null 2>&1
  systemctl disable --now "gre6@$SEL.service" >/dev/null 2>&1
  tunnel_down "$SEL"
  rm -f "$CONF_DIR/$SEL.conf"
  ok "Tunnel $SEL removed."
}

menu() {
  while true; do
    echo
    echo -e "${C}==========================================${N}"
    echo -e "${C}   GRE6 Tunnel Manager (GRE/IPv4 + IPv6)${N}"
    echo -e "${C}==========================================${N}"
    echo "  1) Setup IRAN server    (creates hash code)"
    echo "  2) Setup KHAREJ server  (paste hash code)"
    echo "  3) Show hash code of a tunnel"
    echo "  4) Status / ping test"
    echo "  5) Ping keepalive / auto-restart"
    echo "  6) Restart tunnel"
    echo "  7) Remove tunnel"
    echo "  8) Reinstall prerequisites"
    echo "  0) Exit"
    read -rp "Select: " o
    case "$o" in
      1) setup_iran ;;
      2) setup_foreign ;;
      3) show_code ;;
      4) show_status ;;
      5) watchdog ;;
      6) restart_tunnel ;;
      7) remove_tunnel ;;
      8) install_deps force ;;
      0) exit 0 ;;
      *) err "Invalid option." ;;
    esac
  done
}

# ---------------------------------------------------------- entry
# allow sourcing for tests
[ "${GRE6_SOURCE_ONLY:-0}" = "1" ] && return 0 2>/dev/null

need_root
case "${1:-}" in
  up)    tunnel_up "${2:?name}" ;;
  down)  tunnel_down "${2:?name}" ;;
  watch) tunnel_watch "${2:?name}" ;;
  *)     install_deps; menu ;;
esac
