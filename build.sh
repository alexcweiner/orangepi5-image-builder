#!/usr/bin/env bash
# Builds out/orangepi5-viam-npu.img.xz with Docker.
#   ./build.sh          convert the NPU models, then build the image
#   ./build.sh models   only convert the NPU models (native-arch Linux container; rknn-toolkit2 ships x86_64 and arm64)
#   ./build.sh image    only build the image (needs out/models from a previous run)
# Env: OPI_PASSWORD (default orangepi), VIAM_DEFAULTS (path inside the repo to a viam-defaults.json).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
STEP=${1:-all}
HOST_IDS=(-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)")

docker_platform() {
  case $(docker info --format '{{.Architecture}}') in
    aarch64 | arm64) echo linux/arm64 ;;
    *) echo linux/amd64 ;;
  esac
}

models() {
  # Native arch on purpose: the quantizer hits illegal instructions under x86 emulation on Apple Silicon.
  docker run --rm --platform "$(docker_platform)" -e MAX_JOBS=4 "${HOST_IDS[@]}" -v "$ROOT:/work" -w /work python:3.11-slim bash -c '
    set -e
    apt-get update -qq
    # cmake + build-essential: onnxoptimizer has no arm64 wheels and builds from source there.
    apt-get install -y -qq --no-install-recommends curl ca-certificates libgl1 libglib2.0-0 cmake build-essential >/dev/null
    image/convert-models.sh
    chown -R "$HOST_UID:$HOST_GID" out cache'
}

image() {
  if [[ $(docker_platform) != linux/arm64 ]]; then
    docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null
  fi
  docker build -t orangepi5-image-builder "$ROOT/image"
  local env=(-e OPI_PASSWORD="${OPI_PASSWORD:-orangepi}")
  if [[ -n ${VIAM_DEFAULTS:-} ]]; then env+=(-e VIAM_DEFAULTS="/work/${VIAM_DEFAULTS#./}"); fi
  docker run --rm --privileged -v /dev:/dev -v "$ROOT:/work" "${HOST_IDS[@]}" "${env[@]}" orangepi5-image-builder
}

case $STEP in
  all) models; image ;;
  models) models ;;
  image) image ;;
  *) echo "usage: $0 [all|models|image]" >&2; exit 1 ;;
esac
