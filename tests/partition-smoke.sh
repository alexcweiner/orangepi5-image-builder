#!/usr/bin/env bash
# Integration check inside the builder: touches only a disposable image and loop device.
# docker run --rm --privileged --entrypoint bash -v "$PWD:/work:ro" orangepi5-image-builder /work/tests/partition-smoke.sh
set -euo pipefail
source /work/image/partition.sh
work=$(mktemp -d)
loop=
cleanup() {
  [[ -z $loop ]] || losetup -d "$loop"
  rm -rf "$work"
}
trap cleanup EXIT
img=$work/test.img
truncate -s 128M "$img"
sgdisk -o -n 1:2048:0 -t 1:8300 -c 1:test-root "$img" >/dev/null
original_start=$(part_start "$img" 1)
original_guid=$(part_field "$img" 1 "Partition unique GUID")
loop=$(attach_partition "$img" 1)
mkfs.ext4 -q "$loop"
losetup -d "$loop"
loop=
grow_last_partition "$img" 64
[[ $(part_start "$img" 1) == "$original_start" ]]
[[ $(part_field "$img" 1 "Partition unique GUID") == "$original_guid" ]]
loop=$(attach_partition "$img" 1)
fsck_ok "$loop"
resize2fs "$loop"
shrink_to_filesystem "$img" 1 "$loop" 16
loop=
[[ $(stat -c %s "$img") -lt $((192 * 1024 * 1024)) ]]
[[ $(part_start "$img" 1) == "$original_start" ]]
[[ $(part_field "$img" 1 "Partition unique GUID") == "$original_guid" ]]
loop=$(attach_partition "$img" 1)
fsck_ok "$loop"
echo 'PASS: grow, resize, shrink, GPT integrity, and filesystem integrity'
