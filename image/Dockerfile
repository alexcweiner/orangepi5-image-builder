# Image builder. Runs privileged so it can attach loop devices; arm64 binaries in the chroot
# run through the host's binfmt qemu handler (build.sh registers it).
# customize-rootfs.sh, inside that chroot, compiles opibot/libcheck.so from check.cpp (the
# explore pose checker) and the InternVL describe binary. This image only packs the rootfs.
FROM ubuntu:24.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils parted gdisk e2fsprogs util-linux dosfstools rsync file \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
ENTRYPOINT ["/work/image/build-image.sh"]
