#!/usr/bin/env python3
"""Convert LightStereo-S ONNX to an RK3588 fp16 .rknn file.

Two uint8 RGB inputs, left_img and right_img, NHWC at runtime. The mean and std are
ImageNet's, baked in so the board passes plain pixels. Left in fp16: quantizing a
stereo cost volume to int8 is what breaks the disparity.
"""

import sys
from pathlib import Path

from rknn.api import RKNN

# ImageNet mean and std, scaled to 0-255 pixels, one triple per input.
_MEAN = [123.675, 116.28, 103.53]
_STD = [58.395, 57.12, 57.375]


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} lightstereo-s.onnx lightstereo-s.rknn")
    onnx_path, out = Path(sys.argv[1]), Path(sys.argv[2])
    rknn = RKNN(verbose=False)
    print("--> Config model")
    rknn.config(mean_values=[_MEAN, _MEAN], std_values=[_STD, _STD],
                target_platform="rk3588", optimization_level=2)
    print("--> Loading model")
    if rknn.load_onnx(model=str(onnx_path)) != 0:
        raise SystemExit("load_onnx failed")
    print("--> Building model")
    if rknn.build(do_quantization=False) != 0:
        raise SystemExit("rknn build failed")
    print("--> Export rknn model")
    out.parent.mkdir(parents=True, exist_ok=True)
    if rknn.export_rknn(str(out)) != 0:
        raise SystemExit("export_rknn failed")
    rknn.release()
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
