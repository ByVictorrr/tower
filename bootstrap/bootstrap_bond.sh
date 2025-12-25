#!/usr/bin/env bash
set -euo pipefail

# bond-bootstrap.sh
# Creates a netplan bond (active-backup) from two NICs and applies it.
# Default behavior auto-detects IP/GW/DNS from current default route dev.

BOND="bond0"
MODE="active-backup"
RENDERER="networkd"
IFACES=""
IP_CIDR=""
GW=""
DNS=""
PRIMARY=""
NETPLAN_FILE="/etc/netplan/01-bond0.yaml"
APPLY=0
ROLLBACK_SECONDS=120
ROLLBACK=1
DRY_RUN=0

log() { echo "[$(date +'%F %T')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  sudo $0 --ifaces enp6s0,enp8s0 [--apply]
Options:
  --ifaces A,B            Comma-separated interfaces to bond (required unless autodetect works)
  --bond NAME             Bond name (default: bond0)
  --mode MODE             Bond mode (default: active-backup)
  --renderer R            netplan renderer: networkd|NetworkManager (default: autodetect/networkd)
  --ip CIDR               Static IP like 192.168.4.198/22 (default: auto from default dev)
  --gw IP                 Gateway IP (default: auto from default route)
  --dns IP1,IP2           DNS servers (default: auto from resolvectl or /etc/resolv.conf)
  --primary IFACE         Primary (preferred active) slave (default: auto choose fastest linked)
  --netplan-file PATH     Where to write netplan YAML (default: /etc/netplan/01-bond0.yaml)
  --no-rollback           Disable automatic rollback timer
  --rollback-seconds N    Rollback delay seconds (default: 120)
  --apply                 Actually apply the changes (default: generate only)
  --dry-run               Show what would be done, write nothing
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ifaces) IFACES="${2:-}"; shift 2;;
    --bond) BOND="${2:-}"; shift 2;;
    --mode) MODE="${2:-}"; shift 2;;
    --renderer) RENDERER="${2:-}"; shift 2;;
    --ip) IP_CIDR="${2:-}"; shift 2;;
    --gw) GW="${2:-}"; shift 2;;
    --dns) DNS="${2:-}"; shift 2;;
    --primary) PRIMARY="${2:-}"; shift 2;;
    --netplan-file) NETPLAN_FILE="${2:-}"; shift 2;;
    --no-rollback) ROLLBACK=0; shift;;
    --rollback-seconds) ROLLBACK_SECONDS="${2:-120}"; shift 2;;
    --apply) APPLY=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

have() { command -v "$1" >/dev/null 2>&1; }

have ip || die "Missing 'ip' (iproute2)."
have netplan || die "Missing 'netplan'."
have awk || die "Missing 'awk'."
have grep || die "Missing 'grep'."

detect_renderer() {
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "NetworkManager"
  else
    echo "networkd"
  fi
}

get_default_dev() {
  ip route show default 0.0.0.0/0 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

get_default_gw() {
  ip route show default 0.0.0.0/0 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
}

get_ipv4_cidr() {
  local dev="$1"
  ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4; exit}'
}

get_dns_servers() {
  # Prefer resolvectl if available; fall back to /etc/resolv.conf
  if have resolvectl; then
    # Try global DNS first
    local out
    out="$(resolvectl dns 2>/dev/null | awk '
      /^[[:space:]]*Global:/ {g=1; next}
      g && /DNS Servers:/ {for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF?",":""); print ""; exit}
    ')"
    if [[ -n "${out:-}" ]]; then
      echo "$out"
      return
    fi
  fi
  # /etc/resolv.conf fallback
  awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd, - || true
}

iface_exists() {
  [[ -d "/sys/class/net/$1" ]]
}

# ethtool speed parsing; returns integer Mbps if link detected, else 0
get_speed_mbps() {
  local dev="$1"
  if ! have ethtool; then
    echo 0; return
  fi
  local link speed
  link="$(ethtool "$dev" 2>/dev/null | awk -F': ' '/Link detected:/ {print $2; exit}' || true)"
  speed="$(ethtool "$dev" 2>/dev/null | awk -F': ' '/Speed:/ {print $2; exit}' || true)"
  if [[ "${link:-no}" != "yes" ]]; then
    echo 0; return
  fi
  # speed like "1000Mb/s" or "100Mb/s"
  echo "${speed:-0}" | sed -n 's/^\([0-9]\+\)Mb\/s.*/\1/p' | awk '{print $1+0}'
}

choose_primary() {
  local a="$1" b="$2"
  # Bring links up (best-effort)
  ip link set "$a" up >/dev/null 2>&1 || true
  ip link set "$b" up >/dev/null 2>&1 || true

  local sa sb
  sa="$(get_speed_mbps "$a")"
  sb="$(get_speed_mbps "$b")"

  if [[ "$sb" -gt "$sa" ]]; then
    echo "$b"
  else
    echo "$a"
  fi
}

disable_conflicting_netplan() {
  local ts="$1"
  local a="$2" b="$3" bond="$4"
  shopt -s nullglob
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [[ "$f" == "$NETPLAN_FILE" ]] && continue
    if grep -Eq "(${a}|${b}|${bond})" "$f"; then
      log "Disabling conflicting netplan file: $f"
      mv "$f" "${f}.disabled.${ts}"
    fi
  done
}

write_netplan() {
  local a="$1" b="$2" bond="$3" ipcidr="$4" gw="$5" dns="$6" primary="$7" renderer="$8"
  local dns_yaml=""
  if [[ -n "$dns" ]]; then
    # Convert "1.1.1.1,8.8.8.8" -> "[1.1.1.1, 8.8.8.8]"
    local dns_list
    dns_list="$(echo "$dns" | tr ',' '\n' | awk 'NF{gsub(/^[ \t]+|[ \t]+$/,""); print}' | paste -sd', ' -)"
    dns_yaml=$'      nameservers:\n        addresses: ['"$dns_list"$']\n'
  fi

  cat >"$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: ${renderer}

  ethernets:
    ${a}:
      dhcp4: no
      optional: true
    ${b}:
      dhcp4: no
      optional: true

  bonds:
    ${bond}:
      interfaces: [${a}, ${b}]
      addresses: [${ipcidr}]
${dns_yaml}      routes:
        - to: default
          via: ${gw}
      parameters:
        mode: ${MODE}
        mii-monitor-interval: 100
        primary: ${primary}
        primary-reselect-policy: always
EOF
}

main() {
  local ts
  ts="$(date +'%Y%m%d%H%M%S')"

  # Renderer autodetect unless explicitly set
  if [[ -z "${RENDERER:-}" || "${RENDERER}" == "networkd" ]]; then
    # Keep user's default "networkd" unless NM is active AND user didn't override
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
      # If you want NM instead, pass --renderer NetworkManager
      :
    fi
  fi

  # Autodetect defaults
  local defdev
  defdev="$(get_default_dev || true)"
  [[ -n "${defdev:-}" ]] || die "Could not detect default route device. Provide --ifaces and --ip/--gw."

  if [[ -z "$IFACES" ]]; then
    # pick default dev + another physical-ish iface
    local other=""
    for n in /sys/class/net/*; do
      n="$(basename "$n")"
      [[ "$n" == "lo" ]] && continue
      [[ "$n" == "$defdev" ]] && continue
      [[ "$n" == "$BOND" ]] && continue
      [[ "$n" =~ ^(docker|veth|virbr|br|tap|tun|wg) ]] && continue
      other="$n"; break
    done
    [[ -n "$other" ]] || die "Could not autodetect second interface. Use --ifaces A,B."
    IFACES="${defdev},${other}"
  fi

  IFS=',' read -r IFACE_A IFACE_B <<<"$IFACES"
  [[ -n "${IFACE_A:-}" && -n "${IFACE_B:-}" ]] || die "Bad --ifaces. Use --ifaces enp6s0,enp8s0"

  iface_exists "$IFACE_A" || die "Interface not found: $IFACE_A"
  iface_exists "$IFACE_B" || die "Interface not found: $IFACE_B"

  # If IP/GW/DNS not provided, derive from default dev
  [[ -n "$IP_CIDR" ]] || IP_CIDR="$(get_ipv4_cidr "$defdev" || true)"
  [[ -n "$GW" ]] || GW="$(get_default_gw || true)"
  [[ -n "$DNS" ]] || DNS="$(get_dns_servers || true)"

  [[ -n "$IP_CIDR" ]] || die "Could not detect IPv4 CIDR. Provide --ip (e.g. 192.168.4.198/22)."
  [[ -n "$GW" ]] || die "Could not detect default gateway. Provide --gw."
  [[ -n "$DNS" ]] || log "Warning: could not detect DNS servers; proceeding without nameservers block."

  # Choose primary if not provided
  if [[ -z "$PRIMARY" ]]; then
    PRIMARY="$(choose_primary "$IFACE_A" "$IFACE_B")"
  fi

  log "Plan:"
  log "  bond:      $BOND"
  log "  ifaces:    $IFACE_A + $IFACE_B"
  log "  mode:      $MODE"
  log "  primary:   $PRIMARY"
  log "  ip:        $IP_CIDR"
  log "  gateway:   $GW"
  log "  dns:       ${DNS:-<none>}"
  log "  renderer:  $RENDERER"
  log "  netplan:   $NETPLAN_FILE"
  log "  apply:     $APPLY (rollback: $ROLLBACK, ${ROLLBACK_SECONDS}s)"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "--dry-run set; exiting without changes."
    exit 0
  fi

  mkdir -p /etc/netplan
  local backup_dir="/etc/netplan/backup-${ts}"
  mkdir -p "$backup_dir"
  cp -a /etc/netplan/*.yaml /etc/netplan/*.yml "$backup_dir" 2>/dev/null || true
  log "Backed up existing netplan YAMLs to: $backup_dir"

  disable_conflicting_netplan "$ts" "$IFACE_A" "$IFACE_B" "$BOND"

  write_netplan "$IFACE_A" "$IFACE_B" "$BOND" "$IP_CIDR" "$GW" "$DNS" "$PRIMARY" "$RENDERER"

  chown root:root "$NETPLAN_FILE"
  chmod 600 "$NETPLAN_FILE"

  log "Wrote netplan bond config to $NETPLAN_FILE"
  netplan generate
  log "netplan generate OK"

  if [[ $APPLY -eq 1 ]]; then
    local rollback_script="/run/netplan-bond-rollback-${ts}.sh"
    local pidfile="/run/netplan-bond-rollback-${ts}.pid"

    if [[ $ROLLBACK -eq 1 ]]; then
      cat >"$rollback_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "[\$(date +'%F %T')] Rolling back netplan from $backup_dir" >&2
rm -f /etc/netplan/*.yaml /etc/netplan/*.yml
cp -a "$backup_dir"/* /etc/netplan/ 2>/dev/null || true
netplan apply || true
EOF
      chmod 700 "$rollback_script"
      # Launch rollback timer
      ( nohup bash -c "sleep ${ROLLBACK_SECONDS}; bash '$rollback_script'" >/var/log/bond-bootstrap-rollback.log 2>&1 & echo \$! >"$pidfile" ) || true
      log "Rollback armed: will restore netplan in ${ROLLBACK_SECONDS}s unless cancelled."
      log "  To cancel manually: sudo kill \$(cat $pidfile) 2>/dev/null && sudo rm -f $pidfile $rollback_script"
    fi

    log "Applying netplan..."
    netplan apply
    log "netplan apply done"

    # Quick sanity checks; if they look good, cancel rollback
    sleep 3
    local ok=1
    ip -4 addr show "$BOND" | grep -q "inet " || ok=0
    [[ -r "/proc/net/bonding/$BOND" ]] || ok=0
    if [[ $ok -eq 1 ]]; then
      # if bond exists and has IPv4, likely good
      log "Bond appears up. Cancelling rollback (if armed)."
      if [[ $ROLLBACK -eq 1 && -f "$pidfile" ]]; then
        kill "$(cat "$pidfile")" 2>/dev/null || true
        rm -f "$pidfile" "$rollback_script" || true
      fi
    else
      log "Sanity checks did not pass. Leaving rollback armed."
      log "Check:"
      log "  ip -br addr show $BOND"
      log "  cat /proc/net/bonding/$BOND"
    fi

    log "Verify with:"
    log "  ip -br addr show $BOND"
    log "  cat /proc/net/bonding/$BOND"
  else
    log "Not applying (use --apply to apply)."
  fi
}

main

