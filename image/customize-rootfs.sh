#!/bin/bash
# Runs inside the arm64 chroot of the Armbian rootfs (see build-image.sh).
set -euo pipefail

B=/tmp/opi-build
# shellcheck source=config.env
source "$B/config.env"
: "${OPI_PASSWORD:?}"

export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8

log() { printf '\n--> %s\n' "$*"; }

# Keep package installs from trying to start services inside the chroot.
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
trap 'rm -f /usr/sbin/policy-rc.d' EXIT

log "Installing packages"
apt-get update
apt-get install -y --no-install-recommends \
  network-manager bluez avahi-daemon libnss-mdns openssh-server sudo curl ca-certificates xz-utils \
  python3 v4l-utils libgomp1 build-essential cmake pkg-config libopencv-dev git

log "Networking: NetworkManager owns every interface (viam-agent requires it)"
if [[ -d /etc/netplan ]]; then
  rm -f /etc/netplan/*.yaml
  printf 'network:\n  version: 2\n  renderer: NetworkManager\n' >/etc/netplan/01-network-manager.yaml
  chmod 0600 /etc/netplan/01-network-manager.yaml
fi
systemctl disable systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service 2>/dev/null || true
systemctl enable NetworkManager.service ssh.service avahi-daemon.service

log "Hostname and login"
echo "$OPI_HOSTNAME" >/etc/hostname
hosts=$(grep -v '^127\.0\.1\.1' /etc/hosts || true)
printf '%s\n127.0.1.1 %s\n' "$hosts" "$OPI_HOSTNAME" >/etc/hosts

groups=sudo
for g in video render plugdev dialout i2c spi gpio; do
  if getent group "$g" >/dev/null; then groups+=",$g"; fi
done
id "$OPI_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G "$groups" "$OPI_USER"
echo "$OPI_USER:$OPI_PASSWORD" | chpasswd
passwd -l root
# Skip Armbian's interactive first-login wizard; the user above replaces it.
rm -f /root/.not_logged_in_yet

log "Rockchip NPU runtimes"
install -m 0644 "$B/librknnrt.so" /usr/lib/librknnrt.so
install -m 0644 "$B/vlm/aarch64/library/librkllmrt.so" /usr/lib/librkllmrt.so
install -m 0644 "$B"/vlm/aarch64/include/*.h /usr/local/include/
ldconfig

log "Building the InternVL describe binary"
cmake -S "$B/vlm" -B "$B/vlm/build" -DRK_LIB_PATH=/usr/lib -DCMAKE_BUILD_TYPE=Release
cmake --build "$B/vlm/build" -j"$(nproc)"
# Upstream CMakeLists sets a relative EXECUTABLE_OUTPUT_PATH, so locate the binary instead of assuming it.
vlm_bin=$(find "$B/vlm" -type f -name VLM_NPU -perm -u+x | head -n1)
[[ -n $vlm_bin ]] || { echo "VLM_NPU was not built" >&2; exit 1; }
install -D -m 0755 "$vlm_bin" /opt/orangepi-npu/bin/vlm-describe

log "Building the llm-ask text-model tool"
g++ -O2 -std=c++17 -o /opt/orangepi-npu/bin/llm-ask "$B/llm/llm_ask.cpp" -lrkllmrt

log "Python $OPI_PYTHON venv for NPU tools"
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
export UV_PYTHON_INSTALL_DIR=/opt/orangepi-npu/python UV_CACHE_DIR=/tmp/uv-cache UV_PYTHON_PREFERENCE=only-managed
uv venv --python "$OPI_PYTHON" /opt/orangepi-npu/venv
# shellcheck disable=SC2086
uv pip install --python /opt/orangepi-npu/venv/bin/python $OPI_PIP_PACKAGES
rm -rf /tmp/uv-cache

apt-get clean
rm -rf /var/lib/apt/lists/*
