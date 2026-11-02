# Image builder. Runs privileged so it can attach loop devices; arm64 binaries in the chroot
# run through the host's binfmt qemu handler (build.sh registers it).
# customize-rootfs.sh compiles the standalone InternVL and text-model command-line tools
# inside that chroot. This container is the build environment, not the device OS.
FROM ubuntu:24.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils parted gdisk e2fsprogs util-linux dosfstools rsync file python3 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
ENTRYPOINT ["/work/image/build-image.sh"]
