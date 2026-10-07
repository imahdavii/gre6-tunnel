#!/usr/bin/env bash
# ============================================================
#  GRE6 Tunnel Manager  (GRE over IPv6 / ip6gre)
#  Iran  <---- ip6gre ---->  Foreign
#  - Installs prerequisites automatically
#  - Iran side: enter info once, get a HASH CODE
#  - Foreign side: paste the hash code, done
#  - Persistent (systemd), optional port-forward + watchdog
# ============================================================
set -u

APP="gre6"
# Raw URL of this script on GitHub (used when started via a link)
SCRIPT_URL="https://raw.githubusercontent.com/imahdavii/gre6-tunnel/main/gre6.sh"
CONF_DIR="/etc/gre6tunnel"
BIN="/usr/local/bin/gre6"
SYSTEMD_DIR="/etc/systemd/system"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
ok()   { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[-]${N} $*"; }
info() { echo -e "${C}[*]${N} $*"; }

need_root() { [ "$(id -u)" -eq 0 ] || { err "Run as root."; exit 1; }; }

# ---------------------------------------------------------- deps
install_deps() {
  local missing=0 c
  for c in ip ip6tables curl openssl sha256sum base64 ping systemctl; do
    command -v "$c" >/dev/null 2>&1 || missing=1
  done
  if [ "$missing" -eq 0 ] && [ "${1:-}" != "force" ]; then return 0; fi
  info "Installing prerequisites..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    apt-get install -y iproute2 iptables curl openssl coreutils iputils-ping ip6tables 2>/dev/null \
      || apt-get install -y iproute2 iptables curl openssl coreutils iputils-ping
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y iproute iptables curl openssl coreutils iputils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y iproute iptables curl openssl coreutils iputils
  elif command -v apk >/dev/null 2>&1; then
    apk add iproute2 iptables ip6tables curl openssl coreutils iputils
  else
    warn "Unknown package manager. Install manually: iproute2 iptables curl openssl"
  fi
  modprobe ip6_gre 2>/dev/null || true
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
Description=GRE6 watchdog %i

[Service]
Type=oneshot
ExecStart=$BIN watch %i
EOF
  cat > "$SYSTEMD_DIR/gre6-watch@.timer" <<EOF
[Unit]
Description=GRE6 watchdog timer %i

[Timer]
OnBootSec=90
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

# ---------------------------------------------------------- helpers
valid_v6() { [[ "$1" =~ ^[0-9a-fA-F:]+$ && "$1" == *:* ]]; }
valid_name() { [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]]; }
valid_idx() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 250 ]; }

detect_v6() {
  ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1
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

set_conf_var() { # name key value
  local f="$CONF_DIR/$1.conf"
  if grep -q "^$2=" "$f"; then
    sed -i "s|^$2=.*|$2=\"$3\"|" "$f"
  else
    echo "$2=\"$3\"" >> "$f"
  fi
}

make_conf() { # role name iran6 foreign6 index mtu
  local role=$1 name=$2 ir6=$3 kh6=$4 idx=$5 mtu=$6
  local l6 r6 li6 ri6
  if [ "$role" = "iran" ]; then
    l6=$ir6; r6=$kh6; li6="fd00:$idx::1"; ri6="fd00:$idx::2"
  else
    l6=$kh6; r6=$ir6; li6="fd00:$idx::2"; ri6="fd00:$idx::1"
  fi
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
  cat > "$CONF_DIR/$name.conf" <<EOF
NAME="$name"
ROLE="$role"
IRAN6="$ir6"
FOREIGN6="$kh6"
INDEX="$idx"
MTU="$mtu"
LOCAL6="$l6"
REMOTE6="$r6"
LIP6="$li6"
RIP6="$ri6"
FWD_PORTS=""
EOF
  chmod 600 "$CONF_DIR/$name.conf"
}

# ---------------------------------------------------------- hash code
# payload:  v1;name;iran6;foreign6;index;mtu   + ";" + first 8 hex of sha256
encode_code() { # name iran6 foreign6 index mtu
  local p="v1;$1;$2;$3;$4;$5" sum
  sum=$(printf '%s' "$p" | sha256sum | cut -c1-8)
  printf '%s;%s' "$p" "$sum" | base64 -w0 | tr '+/' '-_' | tr -d '=' | sed 's/^/GRE6-/'
}

DEC_NAME=""; DEC_IR6=""; DEC_KH6=""; DEC_IDX=""; DEC_MTU=""
decode_code() {
  local c="${1#GRE6-}" raw p sum ver
  c=$(printf '%s' "$c" | tr -d ' \r\n' | tr '_-' '/+')
  while [ $(( ${#c} % 4 )) -ne 0 ]; do c="${c}="; done
  raw=$(printf '%s' "$c" | base64 -d 2>/dev/null) || return 1
  sum="${raw##*;}"; p="${raw%;*}"
  [ "$(printf '%s' "$p" | sha256sum | cut -c1-8)" = "$sum" ] || return 1
  IFS=';' read -r ver DEC_NAME DEC_IR6 DEC_KH6 DEC_IDX DEC_MTU <<< "$p"
  [ "$ver" = "v1" ] || return 1
  valid_name "$DEC_NAME" && valid_v6 "$DEC_IR6" && valid_v6 "$DEC_KH6" \
    && valid_idx "$DEC_IDX" && [[ "$DEC_MTU" =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------- firewall / forwarding
ipt_once() { # table chain rule...   (insert if not already present)
  local t=$1 ch=$2; shift 2
  ip6tables -t "$t" -C "$ch" "$@" 2>/dev/null || ip6tables -t "$t" -I "$ch" "$@"
}

fw_clear() {
  ip6tables -t nat -D PREROUTING -j "G6_$NAME" 2>/dev/null
  ip6tables -t nat -F "G6_$NAME" 2>/dev/null
  ip6tables -t nat -X "G6_$NAME" 2>/dev/null
  while ip6tables -t nat -D POSTROUTING -o "$NAME" -m comment --comment "g6-$NAME" -j MASQUERADE 2>/dev/null; do :; done
}

apply_forwards() {
  fw_clear
  [ "$ROLE" = "iran" ] || return 0
  [ -n "${FWD_PORTS:-}" ] || return 0
  ip6tables -t nat -N "G6_$NAME" 2>/dev/null
  ip6tables -t nat -I PREROUTING -j "G6_$NAME"
  local p
  IFS=',' read -ra arr <<< "${FWD_PORTS//-/:}"
  for p in "${arr[@]}"; do
    p="${p// /}"; [ -n "$p" ] || continue
    ip6tables -t nat -A "G6_$NAME" -p tcp --dport "$p" -j DNAT --to-destination "$RIP6"
    ip6tables -t nat -A "G6_$NAME" -p udp --dport "$p" -j DNAT --to-destination "$RIP6"
  done
  ip6tables -t nat -A POSTROUTING -o "$NAME" -m comment --comment "g6-$NAME" -j MASQUERADE
}

# ---------------------------------------------------------- tunnel up/down
tunnel_down() {
  load_conf "$1" || return 1
  fw_clear
  ip link set "$NAME" down 2>/dev/null
  ip -6 tunnel del "$NAME" 2>/dev/null
  return 0
}

tunnel_up() {
  load_conf "$1" || return 1
  modprobe ip6_gre 2>/dev/null || true
  ip link show "$NAME" >/dev/null 2>&1 && { ip link set "$NAME" down 2>/dev/null; ip -6 tunnel del "$NAME" 2>/dev/null; }
  if ! ip -6 tunnel add "$NAME" mode ip6gre local "$LOCAL6" remote "$REMOTE6" ttl 255 encaplimit none; then
    err "Failed to create tunnel (check IPv6 addresses and ip6_gre module)."
    return 1
  fi
  ip link set "$NAME" mtu "$MTU"
  ip -6 addr add "$LIP6/64" dev "$NAME" nodad 2>/dev/null || ip -6 addr add "$LIP6/64" dev "$NAME"
  ip link set "$NAME" up
  sysctl -qw net.ipv6.conf.all.forwarding=1
  # allow GRE from the peer + forwarding through the tunnel
  ip6tables -C INPUT -p gre -s "$REMOTE6" -j ACCEPT 2>/dev/null \
    || ip6tables -I INPUT -p gre -s "$REMOTE6" -j ACCEPT 2>/dev/null
  ipt_once filter FORWARD -i "$NAME" -j ACCEPT
  ipt_once filter FORWARD -o "$NAME" -j ACCEPT
  ipt_once filter INPUT -i "$NAME" -j ACCEPT
  apply_forwards
  return 0
}

tunnel_watch() {
  load_conf "$1" || return 1
  if ! ping -6 -c3 -W2 "$RIP6" >/dev/null 2>&1; then
    logger -t gre6 "tunnel $NAME down, restarting"
    systemctl restart "gre6@$NAME.service"
  fi
}

enable_service() { systemctl enable --now "gre6@$1.service" >/dev/null 2>&1; }

# ---------------------------------------------------------- menu actions
ask() { # prompt default -> REPLY
  local d="${2:-}" a
  if [ -n "$d" ]; then read -rp "$1 [$d]: " a; REPLY="${a:-$d}"; else read -rp "$1: " a; REPLY="$a"; fi
}

setup_iran() {
  echo; info "=== IRAN server setup ==="
  local name idx mtu ir6 kh6
  ask "Tunnel name (letters/digits, max 15)" "gre6a"; name="$REPLY"
  valid_name "$name" || { err "Bad name."; return; }
  [ -f "$CONF_DIR/$name.conf" ] && { err "Tunnel $name already exists. Remove it first."; return; }
  ask "Iran server public IPv6" "$(detect_v6)"; ir6="$REPLY"
  valid_v6 "$ir6" || { err "Invalid IPv6."; return; }
  ask "Foreign server public IPv6" ""; kh6="$REPLY"
  valid_v6 "$kh6" || { err "Invalid IPv6."; return; }
  ask "Inner subnet index 1-250 (inner IPv6: fd00:N::1 / fd00:N::2)" "10"; idx="$REPLY"
  valid_idx "$idx" || { err "Bad index."; return; }
  ask "MTU" "1380"; mtu="$REPLY"
  [[ "$mtu" =~ ^[0-9]+$ ]] || { err "Bad MTU."; return; }

  make_conf iran "$name" "$ir6" "$kh6" "$idx" "$mtu"
  self_install || { rm -f "$CONF_DIR"/*.conf.new; return; }
  tunnel_up "$name" || return
  enable_service "$name"
  ok "Iran side is up:  ${G}fd00:$idx::1${N}  <->  fd00:$idx::2 (foreign)"
  echo
  echo -e "${Y}Copy this HASH CODE and use option 2 on the FOREIGN server:${N}"
  echo
  encode_code "$name" "$ir6" "$kh6" "$idx" "$mtu"; echo; echo
}

setup_foreign() {
  echo; info "=== FOREIGN server setup ==="
  read -rp "Paste hash code: " code
  if ! decode_code "$code"; then err "Invalid or corrupted hash code."; return; fi
  [ -f "$CONF_DIR/$DEC_NAME.conf" ] && { err "Tunnel $DEC_NAME already exists here. Remove it first."; return; }
  info "Tunnel: $DEC_NAME | Iran: $DEC_IR6 | Foreign: $DEC_KH6 | index: $DEC_IDX | MTU: $DEC_MTU"
  local mine; mine="$(detect_v6)"
  if [ -n "$mine" ] && [ "$mine" != "$DEC_KH6" ]; then
    warn "This server's IPv6 ($mine) differs from the foreign IPv6 in the code ($DEC_KH6)."
    read -rp "Continue anyway? [y/N]: " y; [[ "$y" =~ ^[Yy]$ ]] || return
  fi
  make_conf foreign "$DEC_NAME" "$DEC_IR6" "$DEC_KH6" "$DEC_IDX" "$DEC_MTU"
  self_install || { rm -f "$CONF_DIR"/*.conf.new; return; }
  tunnel_up "$DEC_NAME" || return
  enable_service "$DEC_NAME"
  ok "Foreign side is up:  ${G}fd00:$DEC_IDX::2${N}  <->  fd00:$DEC_IDX::1 (Iran)"
  info "Test: ping -6 fd00:$DEC_IDX::1"
}

show_code() {
  pick_tunnel || return
  load_conf "$SEL" || return
  echo; echo -e "${Y}Hash code for $SEL:${N}"; encode_code "$NAME" "$IRAN6" "$FOREIGN6" "$INDEX" "$MTU"; echo; echo
}

show_status() {
  pick_tunnel || return
  load_conf "$SEL" || return
  echo
  ip -d addr show "$NAME" 2>/dev/null || warn "Interface $NAME not present."
  echo
  info "Role: $ROLE | local6: $LOCAL6 | remote6: $REMOTE6"
  info "Inner IPv6: $LIP6 -> $RIP6"
  [ -n "${FWD_PORTS:-}" ] && info "Forwarded ports: $FWD_PORTS"
  echo; info "Ping6 $RIP6 ..."
  ping -6 -c4 -W2 "$RIP6" && ok "Tunnel is working." || err "No reply from the other side."
}

port_forward() {
  pick_tunnel || return
  load_conf "$SEL" || return
  [ "$ROLE" = "iran" ] || { warn "Port forwarding is only for the Iran side."; return; }
  echo "Current: ${FWD_PORTS:-none}"
  echo "Enter ports to forward from Iran -> foreign (${RIP6})."
  echo "Examples: 443   |   80,443,8443   |   2000-3000   (empty = disable)"
  read -rp "Ports: " ports
  ports="${ports// /}"
  if [ -n "$ports" ] && ! [[ "$ports" =~ ^[0-9,:-]+$ ]]; then err "Bad format."; return; fi
  set_conf_var "$SEL" FWD_PORTS "$ports"
  load_conf "$SEL"; apply_forwards
  ok "Forwarding updated: ${ports:-disabled}"
}

watchdog() {
  pick_tunnel || return
  echo "  1) Enable watchdog (ping every 60s, auto-restart)"
  echo "  2) Disable watchdog"
  read -rp "Choice: " c
  write_units
  case "$c" in
    1) systemctl enable --now "gre6-watch@$SEL.timer" >/dev/null 2>&1 && ok "Watchdog enabled." ;;
    2) systemctl disable --now "gre6-watch@$SEL.timer" >/dev/null 2>&1 && ok "Watchdog disabled." ;;
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
    echo -e "${C}      GRE6 Tunnel Manager (ip6gre)${N}"
    echo -e "${C}==========================================${N}"
    echo "  1) Setup IRAN server   (creates hash code)"
    echo "  2) Setup FOREIGN server (paste hash code)"
    echo "  3) Show hash code of a tunnel"
    echo "  4) Status / ping test"
    echo "  5) Port forwarding (Iran side)"
    echo "  6) Watchdog (auto-restart)"
    echo "  7) Restart tunnel"
    echo "  8) Remove tunnel"
    echo "  9) Reinstall prerequisites"
    echo "  0) Exit"
    read -rp "Select: " o
    case "$o" in
      1) setup_iran ;;
      2) setup_foreign ;;
      3) show_code ;;
      4) show_status ;;
      5) port_forward ;;
      6) watchdog ;;
      7) restart_tunnel ;;
      8) remove_tunnel ;;
      9) install_deps force ;;
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
