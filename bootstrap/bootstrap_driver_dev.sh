#!/usr/bin/env bash
set -euo pipefail

WITH_FIRMWARE=0
WITH_VIRT=0
WITH_EBPF=0
WITH_CONTAINERS=0
WITH_SYNC=0
ENABLE_DEB_SRC=0

usage() {
  cat <<'EOF'
Usage: sudo ./bootstrap_driver_dev.sh [options]

Options:
  --with-firmware     Add common firmware dev tools (ARM GCC, OpenOCD, etc.)
  --with-virt         Add KVM/QEMU/libvirt tooling (useful for kernel testing)
  --with-ebpf         Add eBPF tracing tools (bpftrace, bpftool, etc.)
  --with-containers   Add Docker/Podman basics from Ubuntu repos
  --with-sync         Install Syncthing for file sync (server + clients)
  --enable-deb-src    Enable deb-src lines (useful for apt source/build-dep)
  -h, --help          Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-firmware)   WITH_FIRMWARE=1 ;;
    --with-virt)       WITH_VIRT=1 ;;
    --with-ebpf)       WITH_EBPF=1 ;;
    --with-containers) WITH_CONTAINERS=1 ;;
    --with-sync)       WITH_SYNC=1 ;;
    --enable-deb-src)  ENABLE_DEB_SRC=1 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

if [[ ${EUID:-99999} -ne 0 ]]; then
  echo "Run as root (e.g., sudo $0 ...)"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[*] Updating apt indexes..."
apt-get update -y

echo "[*] Installing base dev + kernel module toolchain..."
BASE_PKGS=(
  build-essential dkms git curl wget ca-certificates gnupg lsb-release
  pkg-config cmake ninja-build meson autoconf automake libtool patch
  python3 python3-pip python3-venv
  bc bison flex rsync fakeroot
  libssl-dev libelf-dev libncurses-dev dwarves libdw-dev elfutils
  clang llvm lld lldb
  sparse coccinelle
  gdb gdb-multiarch strace ltrace valgrind
  htop tmux ripgrep jq
  pciutils usbutils ethtool iproute2
)

apt-get install -y "${BASE_PKGS[@]}"

echo "[*] Installing kernel headers/tools for the running kernel + generic metapackages..."
KREL="$(uname -r)"
apt-get install -y "linux-headers-${KREL}" linux-headers-generic || true
apt-get install -y linux-tools-common linux-tools-generic "linux-tools-${KREL}" || true
apt-get install -y trace-cmd || true

echo "[*] Optional: enable deb-src lines..."
if [[ $ENABLE_DEB_SRC -eq 1 ]]; then
  # Uncomment deb-src lines in /etc/apt/sources.list (best-effort)
  sed -i -E 's/^[#[:space:]]*(deb-src[[:space:]]+)/\1/g' /etc/apt/sources.list || true
  sed -i -E 's/^[#[:space:]]*(deb-src[[:space:]]+http)/deb-src http/g' /etc/apt/sources.list || true
  apt-get update -y
fi

echo "[*] Optional components..."
if [[ $WITH_EBPF -eq 1 ]]; then
  apt-get install -y bpftrace bpftool bpfcc-tools || true
fi

if [[ $WITH_VIRT -eq 1 ]]; then
  apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst || true
  systemctl enable --now libvirtd || true
fi

if [[ $WITH_FIRMWARE -eq 1 ]]; then
  apt-get install -y gcc-arm-none-eabi gdb-multiarch openocd dfu-util minicom picocom || true
fi

if [[ $WITH_CONTAINERS -eq 1 ]]; then
  # Ubuntu repo versions (simple + stable). If you want Docker CE, install from Docker's repo instead.
  apt-get install -y docker.io docker-compose-plugin podman || true
  systemctl enable --now docker || true
fi

if [[ $WITH_SYNC -eq 1 ]]; then
  apt-get install -y syncthing || true
  cat <<'EOT'

[+] Syncthing installed.

To run Syncthing for your user (recommended), log in as that user and enable:
  systemctl --user enable --now syncthing

If this is a headless server, you can access the Syncthing Web UI via SSH tunnel:
  ssh -L 8384:127.0.0.1:8384 <user>@<server>

Firewall ports commonly needed (if you are not using a VPN):
  TCP/UDP 22000 (sync)
  UDP 21027 (local discovery)

EOT
fi

echo
echo "[✓] Done."
echo "    Kernel: ${KREL}"
echo "    PCIe tip: start with 'lspci -nnk' and 'sudo lspci -vv'."
