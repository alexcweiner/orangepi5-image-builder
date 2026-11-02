# GPT helpers for growing and shrinking the root partition of a disk image. Sourced by build-image.sh.
# shellcheck shell=bash

SECTOR=512

part_field() {
  sgdisk -i "$2" "$1" | sed -n "s/^$3: *//p"
}

part_start() { part_field "$1" "$2" "First sector" | awk '{print $1}'; }
part_last() { part_field "$1" "$2" "Last sector" | awk '{print $1}'; }
last_part_number() { sgdisk -p "$1" | awk '/^ +[0-9]+ /{n=$1} END{print n}'; }

# Rewrites partition N to end at END (0 = end of disk), keeping its start, type, GUID, name and attribute bits.
recreate_partition() {
  local img=$1 n=$2 end=$3
  local start type guid name attrs args=()
  start=$(part_start "$img" "$n")
  type=$(part_field "$img" "$n" "Partition GUID code" | awk '{print $1}')
  guid=$(part_field "$img" "$n" "Partition unique GUID")
  name=$(part_field "$img" "$n" "Partition name" | sed "s/^'\(.*\)'$/\1/")
  attrs=$((16#$(part_field "$img" "$n" "Attribute flags")))
  for bit in $(seq 0 63); do
    if (( (attrs >> bit) & 1 )); then args+=(-A "$n:set:$bit"); fi
  done
  sgdisk -d "$n" -n "$n:$start:$end" -t "$n:$type" -u "$n:$guid" -c "$n:$name" "${args[@]}" "$img" >/dev/null
}

# Appends MB to the image and extends its last partition to the new end.
grow_last_partition() {
  local img=$1 mb=$2 n
  truncate -s "+${mb}M" "$img"
  sgdisk -e "$img" >/dev/null
  n=$(last_part_number "$img")
  recreate_partition "$img" "$n" 0
}

# Attaches partition N of IMG to a loop device and prints the device.
attach_partition() {
  local img=$1 n=$2 start last
  start=$(part_start "$img" "$n")
  last=$(part_last "$img" "$n")
  losetup -f --show -o $((start * SECTOR)) --sizelimit $(((last - start + 1) * SECTOR)) "$img"
}

fsck_ok() {
  local rc=0
  e2fsck -fy "$1" || rc=$?
  (( rc <= 1 )) || { echo "e2fsck failed on $1 ($rc)" >&2; return 1; }
}

# Shrinks the (unmounted) ext4 filesystem on LOOP to its minimum plus SLACK_MB, detaches LOOP,
# then shrinks partition N and truncates the image to match.
shrink_to_filesystem() {
  local img=$1 n=$2 loop=$3 slack_mb=${4:-512}
  local start blocks bsize fs_bytes new_last
  start=$(part_start "$img" "$n")
  fsck_ok "$loop"
  resize2fs -M "$loop"
  blocks=$(dumpe2fs -h "$loop" 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,"",$2); print $2}')
  bsize=$(dumpe2fs -h "$loop" 2>/dev/null | awk -F: '/^Block size/{gsub(/ /,"",$2); print $2}')
  fs_bytes=$((blocks * bsize + slack_mb * 1024 * 1024))
  resize2fs "$loop" "$((fs_bytes / 1024))K"
  losetup -d "$loop"

  new_last=$((start + fs_bytes / SECTOR - 1))
  recreate_partition "$img" "$n" "$new_last"
  truncate -s $(((new_last + 1 + 2048) * SECTOR)) "$img"
  sgdisk -e "$img" >/dev/null 2>&1 || true
  sgdisk -v "$img" | grep -q "No problems found" || { sgdisk -v "$img" >&2; return 1; }
}
