#!/usr/bin/env bash
# Converts YOLOv8 and FastSAM-s to RK3588 INT8 .rknn files.
# rknn-toolkit2 runs on x86_64 or arm64 Linux; build.sh runs this inside a python:3.11 container.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=config.env
source "$HERE/config.env"

OUT=${OUT_DIR:-$ROOT/out}/models
CACHE=${CACHE_DIR:-$ROOT/cache}
mkdir -p "$OUT" "$CACHE"

yolo_ready=0
fastsam_ready=0
lightstereo_ready=0
[[ -f $OUT/yolov8n.rknn && -f $OUT/yolov8n-pose.rknn && -f $OUT/yolov8n-seg.rknn ]] && yolo_ready=1
[[ -f $OUT/fastsam-s.rknn ]] && fastsam_ready=1
[[ -f $OUT/lightstereo-s.rknn ]] && lightstereo_ready=1
if [[ $yolo_ready -eq 1 && $fastsam_ready -eq 1 && $lightstereo_ready -eq 1 ]]; then
  echo "NPU .rknn models already in $OUT"
  exit 0
fi

python3 -m pip install --quiet --upgrade pip
python3 -m pip install --quiet --extra-index-url https://download.pytorch.org/whl/cpu \
  "rknn-toolkit2==${RKNN_VERSION}" "onnx==1.16.1" "numpy<2" "setuptools<81"

ZOO=$CACHE/rknn_model_zoo-$RKNN_MODEL_ZOO_REF
if [[ ! -d $ZOO ]]; then
  curl -fsSL "https://codeload.github.com/airockchip/rknn_model_zoo/tar.gz/$RKNN_MODEL_ZOO_REF" | tar -xz -C "$CACHE"
fi

if [[ $yolo_ready -eq 0 ]]; then
  convert() {
    local example=$1 onnx=$2 out=$3
    local dir=$ZOO/examples/$example
    if [[ ! -s $dir/model/$onnx ]]; then
      curl -fL --retry 3 -o "$dir/model/$onnx" "$YOLO_ONNX_BASE/$example/$onnx"
    fi
    # convert.py resolves the COCO calibration subset relative to its own directory.
    (cd "$dir/python" && python3 convert.py "../model/$onnx" rk3588 i8 "$OUT/$out")
  }

  convert yolov8 yolov8n.onnx yolov8n.rknn
  convert yolov8_pose yolov8n-pose.onnx yolov8n-pose.rknn
  convert yolov8_seg yolov8n-seg.onnx yolov8n-seg.rknn
  cp "$ZOO/examples/yolov8/model/bus.jpg" "$OUT/bus.jpg"
fi

if [[ $fastsam_ready -eq 0 ]]; then
  PT=$CACHE/FastSAM-s.pt
  if [[ ! -s $PT ]]; then
    curl -fL --retry 3 -o "$PT.part" "$FASTSAM_PT_URL"
    mv "$PT.part" "$PT"
  fi
  echo "$FASTSAM_PT_SHA256  $PT" | sha256sum -c -
  # Export uses torch. Re-pin the quantizer afterwards; ultralytics may upgrade numpy or onnx.
  python3 -m pip install --quiet --extra-index-url https://download.pytorch.org/whl/cpu \
    "ultralytics==${FASTSAM_ULTRALYTICS}" "onnx==1.16.1"
  python3 "$HERE/fastsam_onnx.py" "$PT" "$CACHE/FastSAM-s-head.onnx"
  python3 -m pip install --quiet --extra-index-url https://download.pytorch.org/whl/cpu \
    "rknn-toolkit2==${RKNN_VERSION}" "onnx==1.16.1" "numpy<2" "setuptools<81"
  python3 "$HERE/fastsam_rknn.py" "$CACHE/FastSAM-s-head.onnx" \
    "$ZOO/datasets/COCO/coco_subset_20.txt" "$OUT/fastsam-s.rknn"
fi

if [[ $lightstereo_ready -eq 0 ]]; then
  python3 -m pip install --quiet --extra-index-url https://download.pytorch.org/whl/cpu \
    "rknn-toolkit2==${RKNN_VERSION}" "onnx==1.16.1" "numpy<2" "setuptools<81"
  ONNX=$CACHE/lightstereo-s.onnx
  if [[ ! -s $ONNX ]]; then
    curl -fL --retry 3 -o "$ONNX.part" "$LIGHTSTEREO_ONNX_URL"
    mv "$ONNX.part" "$ONNX"
  fi
  echo "$LIGHTSTEREO_ONNX_SHA256  $ONNX" | sha256sum -c -
  python3 "$HERE/lightstereo_rknn.py" "$ONNX" "$OUT/lightstereo-s.rknn"
fi

ls -l "$OUT"
