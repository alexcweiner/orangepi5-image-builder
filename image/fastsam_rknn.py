#!/usr/bin/env python3
"""Quantize the stripped FastSAM-s ONNX to an RK3588 INT8 .rknn file.

Input is uint8 RGB, 0-255, NHWC at runtime. mean 0 / std 255 is what turns that into
the 0-1 float the Ultralytics graph was trained on. auto_hybrid keeps the mask head
accurate where plain INT8 smears it.
"""

import sys
from pathlib import Path

from rknn.api import RKNN


def absolute_dataset(listing: Path, dest: Path) -> Path:
    root = listing.parent
    lines = []
    for line in listing.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        path = Path(line)
        if not path.is_absolute():
            path = (root / path).resolve()
        if not path.is_file():
            raise SystemExit(f"missing calibration image: {path}")
        lines.append(str(path))
    if not lines:
        raise SystemExit(f"no calibration images in {listing}")
    dest.write_text("\n".join(lines) + "\n")
    return dest


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(f"usage: {sys.argv[0]} fastsam-head.onnx coco_subset_20.txt fastsam-s.rknn")
    onnx_path, listing, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    dataset = absolute_dataset(listing, onnx_path.with_name("fastsam-calib.txt"))

    rknn = RKNN(verbose=False)
    print("--> Config model")
    rknn.config(mean_values=[[0, 0, 0]], std_values=[[255, 255, 255]], target_platform="rk3588")
    print("--> Loading model")
    if rknn.load_onnx(model=str(onnx_path)) != 0:
        raise SystemExit("load_onnx failed")
    print("--> Building model")
    if rknn.build(do_quantization=True, dataset=str(dataset), auto_hybrid=True) != 0:
        raise SystemExit("rknn build failed")
    print("--> Export rknn model")
    out.parent.mkdir(parents=True, exist_ok=True)
    if rknn.export_rknn(str(out)) != 0:
        raise SystemExit("export_rknn failed")
    rknn.release()
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
