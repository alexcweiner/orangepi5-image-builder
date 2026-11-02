#!/usr/bin/env bash
# Customizes the pinned Armbian Orange Pi 5 image into out/orangepi5-viam-npu.img.xz.
# Needs root, loop devices, and an arm64 binfmt handler. build.sh runs it in the privileged builder container.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=config.env
source "$HERE/config.env"
# shellcheck source=partition.sh
source "$HERE/partition.sh"

CACHE=${CACHE_DIR:-$ROOT/cache}
OUT=${OUT_DIR:-$ROOT/out}
MODELS=$OUT/models
WORK=${WORK_DIR:-/tmp/opi-work}
OPI_PASSWORD=${OPI_PASSWORD:-orangepi}
VIAM_DEFAULTS=${VIAM_DEFAULTS:-$HERE/viam-defaults.json}
VIAM_CONFIG=${VIAM_CONFIG:-}

log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[[ $(id -u) -eq 0 ]] || die "run as root (build.sh runs this in a privileged container)"
for m in yolov8n.rknn yolov8n-pose.rknn yolov8n-seg.rknn fastsam-s.rknn lightstereo-s.rknn bus.jpg; do
  [[ -s $MODELS/$m ]] || die "missing $MODELS/$m; run image/convert-models.sh first"
done
if [[ $(uname -m) != aarch64 ]]; then
  # binfmt_misc is kernel-wide, but Docker doesn't mount it inside containers.
  if [[ ! -e /proc/sys/fs/binfmt_misc/status ]]; then
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
  fi
  [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
    || die "no arm64 binfmt handler; run: docker run --privileged --rm tonistiigi/binfmt --install arm64"
fi
[[ -f $VIAM_DEFAULTS ]] || die "missing $VIAM_DEFAULTS"
if [[ -n $VIAM_CONFIG ]]; then
  python3 "$HERE/viam-config.py" validate "$VIAM_CONFIG"
fi

fetch() {
  local url=$1 dest=$2 sha=${3:-}
  if [[ ! -s $dest ]]; then
    curl -fL --retry 5 --retry-delay 5 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  if [[ -n $sha ]] && ! echo "$sha  $dest" | sha256sum -c --status -; then
    rm -f "$dest"
    die "checksum mismatch for $url"
  fi
}

MNT=$WORK/rootfs
LOOP=
cleanup() {
  set +e
  for m in dev/pts dev sys proc ""; do
    if mountpoint -q "$MNT/$m"; then umount "$MNT/$m" 2>/dev/null || umount -l "$MNT/$m"; fi
  done
  [[ -n $LOOP ]] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$CACHE" "$OUT" "$WORK" "$MNT"

log "Downloading pinned inputs"
fetch "$ARMBIAN_URL" "$CACHE/$ARMBIAN_IMAGE" "$ARMBIAN_SHA256"
fetch "https://huggingface.co/$VLM_HF_REPO/resolve/$VLM_HF_REV/$VLM_VISION_FILE" "$CACHE/$VLM_VISION_FILE" "$VLM_VISION_SHA256"
fetch "https://huggingface.co/$VLM_HF_REPO/resolve/$VLM_HF_REV/$VLM_LLM_FILE" "$CACHE/$VLM_LLM_FILE" "$VLM_LLM_SHA256"
fetch "https://huggingface.co/$WRITER_HF_REPO/resolve/$WRITER_HF_REV/$WRITER_HF_PATH" "$CACHE/$WRITER_FILE" "$WRITER_SHA256"
fetch "$RKNNRT_URL" "$CACHE/librknnrt-$RKNN_VERSION.so"
fetch "https://codeload.github.com/$VLM_SRC_REPO/tar.gz/$VLM_SRC_REF" "$CACHE/vlm-src-$VLM_SRC_REF.tar.gz"

log "Downloading current stable viam-agent and viam-server"
rm -f "$WORK/viam-agent" "$WORK/viam-server" "$WORK/preinstall.sh"
fetch "$VIAM_AGENT_URL" "$WORK/viam-agent"
fetch "$VIAM_SERVER_URL" "$WORK/viam-server"
fetch "$VIAM_PREINSTALL_URL" "$WORK/preinstall.sh"

IMG=$WORK/$IMAGE_NAME.img
log "Unpacking $ARMBIAN_IMAGE"
xz -dc "$CACHE/$ARMBIAN_IMAGE" >"$IMG"
if [[ -n $VIAM_CONFIG ]]; then chmod 0600 "$IMG"; fi

log "Growing root partition by ${EXTRA_IMAGE_MB} MiB"
grow_last_partition "$IMG" "$EXTRA_IMAGE_MB"
PART=$(last_part_number "$IMG")
LOOP=$(attach_partition "$IMG" "$PART")
fsck_ok "$LOOP"
resize2fs "$LOOP"
mount "$LOOP" "$MNT"
[[ -x $MNT/bin/bash && -e $MNT/lib/ld-linux-aarch64.so.1 ]] || die "partition $PART is not an arm64 rootfs"

log "Staging files"
rsync -a --chown=root:root --chmod=Du=rwx,Dgo=rx "$ROOT/rootfs/" "$MNT/"
install -d "$MNT/opt/orangepi-npu/models" "$MNT/opt/orangepi-npu/share"
install -m 0644 "$MODELS"/yolov8n.rknn "$MODELS"/yolov8n-pose.rknn "$MODELS"/yolov8n-seg.rknn \
  "$MODELS"/fastsam-s.rknn "$MODELS"/lightstereo-s.rknn "$MNT/opt/orangepi-npu/models/"
install -m 0644 "$CACHE/$VLM_VISION_FILE" "$CACHE/$VLM_LLM_FILE" "$CACHE/$WRITER_FILE" "$MNT/opt/orangepi-npu/models/"
install -m 0644 "$MODELS/bus.jpg" "$MNT/opt/orangepi-npu/share/bus.jpg"

BUILD=$MNT/tmp/opi-build
rm -rf "$BUILD"
install -d "$BUILD/vlm"
tar -xzf "$CACHE/vlm-src-$VLM_SRC_REF.tar.gz" -C "$BUILD/vlm" --strip-components=1
install -m 0644 "$HERE/vlm/describe_main.cpp" "$BUILD/vlm/src/main.cpp"
install -D -m 0644 "$HERE/llm/llm_ask.cpp" "$BUILD/llm/llm_ask.cpp"
install -m 0644 "$CACHE/librknnrt-$RKNN_VERSION.so" "$BUILD/librknnrt.so"
install -m 0644 "$HERE/config.env" "$BUILD/config.env"
install -m 0755 "$HERE/customize-rootfs.sh" "$BUILD/customize-rootfs.sh"

mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"

RESOLV_BACKUP=
if [[ -e $MNT/etc/resolv.conf || -L $MNT/etc/resolv.conf ]]; then
  RESOLV_BACKUP=$MNT/etc/resolv.conf.opi-build
  mv "$MNT/etc/resolv.conf" "$RESOLV_BACKUP"
fi
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"

log "Customizing rootfs in arm64 chroot"
chroot "$MNT" /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root TERM=dumb OPI_PASSWORD="$OPI_PASSWORD" \
  /bin/bash /tmp/opi-build/customize-rootfs.sh

rm -f "$MNT/etc/resolv.conf"
if [[ -n $RESOLV_BACKUP ]]; then mv "$RESOLV_BACKUP" "$MNT/etc/resolv.conf"; fi
rm -rf "$BUILD"

log "Installing viam-agent (preinstall.sh) and viam-server"
# Install the generic agent first, then optionally add the explicitly supplied credentials.
(cd "$WORK" && printf 'y\n\n' | VIAM_AGENT_PATH="$WORK/viam-agent" DEFAULTS_PATH="$VIAM_DEFAULTS" sh ./preinstall.sh "$MNT")
[[ -L $MNT/opt/viam/bin/viam-agent && -f $MNT/usr/local/lib/systemd/system/viam-agent.service ]] \
  || die "viam-agent preinstall did not land in the rootfs"
[[ ! -e $MNT/etc/viam.json ]] || die "supply credentials through VIAM_CONFIG, not the rootfs overlay"
if [[ -n $VIAM_CONFIG ]]; then
  log "Installing supplied Viam machine cloud credentials"
  python3 "$HERE/viam-config.py" install "$VIAM_CONFIG" "$MNT/etc/viam.json"
fi
install -m 0755 "$WORK/viam-server" "$MNT/opt/viam/cache/viam-server-factory-aarch64"
ln -sfn /opt/viam/cache/viam-server-factory-aarch64 "$MNT/opt/viam/bin/viam-server"

fstrim "$MNT" 2>/dev/null || true
for m in dev/pts dev sys proc; do umount "$MNT/$m"; done
umount "$MNT"

log "Shrinking root filesystem"
shrink_to_filesystem "$IMG" "$PART" "$LOOP" 512 || die "shrinking the image failed"
LOOP=

log "Compressing"
# A configured image contains machine credentials; restrict the output artifact too.
if [[ -n $VIAM_CONFIG ]]; then umask 077; fi
rm -f "$OUT/$IMAGE_NAME.img.xz"
xz -T0 -6 -c "$IMG" >"$OUT/$IMAGE_NAME.img.xz"
(cd "$OUT" && sha256sum "$IMAGE_NAME.img.xz" >"$IMAGE_NAME.img.xz.sha256")
rm -f "$IMG"
if [[ -n ${HOST_UID:-} ]]; then chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$OUT" "$CACHE"; fi
ls -lh "$OUT/$IMAGE_NAME.img.xz"
