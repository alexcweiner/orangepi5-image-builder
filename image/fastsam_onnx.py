#!/usr/bin/env python3
"""Export FastSAM-s and cut the graph down to the raw segmentation head.

Ultralytics exports a decoded tensor, (1, 37, 8400), plus the mask prototype.
The RK3588 path keeps the nine per-scale convs — box (64-channel DFL), one class
score, 32 mask coefficients — and the 32x160x160 prototype. DFL, NMS and the
mask composition run on the CPU. Names are the ultralytics 8.4 FastSAM-s graph
exported at opset 12 with simplify left off.
"""

import sys
from pathlib import Path

import onnx
from onnx import TensorProto, helper

# proto first, then box / class / coefficients at strides 8, 16 and 32.
HEADS = (
    ("output1", (1, 32, 160, 160)),
    ("/model.22/cv2.0/cv2.0.2/Conv_output_0", (1, 64, 80, 80)),
    ("/model.22/cv3.0/cv3.0.2/Conv_output_0", (1, 1, 80, 80)),
    ("/model.22/cv4.0/cv4.0.2/Conv_output_0", (1, 32, 80, 80)),
    ("/model.22/cv2.1/cv2.1.2/Conv_output_0", (1, 64, 40, 40)),
    ("/model.22/cv3.1/cv3.1.2/Conv_output_0", (1, 1, 40, 40)),
    ("/model.22/cv4.1/cv4.1.2/Conv_output_0", (1, 32, 40, 40)),
    ("/model.22/cv2.2/cv2.2.2/Conv_output_0", (1, 64, 20, 20)),
    ("/model.22/cv3.2/cv3.2.2/Conv_output_0", (1, 1, 20, 20)),
    ("/model.22/cv4.2/cv4.2.2/Conv_output_0", (1, 32, 20, 20)),
)


def export_onnx(weights: Path) -> Path:
    from ultralytics import FastSAM

    exported = Path(FastSAM(str(weights)).export(format="onnx", imgsz=640, opset=12, simplify=False))
    return exported


def strip_postprocess(source: Path, dest: Path) -> None:
    model = onnx.load(source)
    produced = {name for node in model.graph.node for name in node.output}
    missing = [name for name, _ in HEADS if name not in produced]
    if missing:
        raise SystemExit(
            "FastSAM graph is missing the raw head tensors "
            f"{missing}. Export with ultralytics 8.4, opset 12, simplify=False."
        )

    producer = {}
    for node in model.graph.node:
        for out in node.output:
            producer[out] = node

    needed = set()
    queue = [name for name, _ in HEADS]
    while queue:
        tensor = queue.pop()
        if tensor in needed:
            continue
        needed.add(tensor)
        node = producer.get(tensor)
        if node is not None:
            queue.extend(node.input)

    kept = [node for node in model.graph.node if any(out in needed for out in node.output)]
    del model.graph.node[:]
    model.graph.node.extend(kept)

    used = {inp for node in model.graph.node for inp in node.input}
    inits = [init for init in model.graph.initializer if init.name in used]
    del model.graph.initializer[:]
    model.graph.initializer.extend(inits)

    del model.graph.output[:]
    for name, shape in HEADS:
        model.graph.output.append(helper.make_tensor_value_info(name, TensorProto.FLOAT, list(shape)))

    images = model.graph.input[0]
    del model.graph.input[:]
    model.graph.input.append(images)
    del model.graph.value_info[:]

    onnx.checker.check_model(model)
    dest.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, dest)
    print(f"wrote {dest} ({len(kept)} nodes, {len(HEADS)} outputs)")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} FastSAM-s.pt output.onnx")
    weights, dest = Path(sys.argv[1]), Path(sys.argv[2])
    if not weights.is_file():
        raise SystemExit(f"missing weights: {weights}")
    raw = weights.with_suffix(".onnx")
    if not raw.is_file() or raw.stat().st_mtime < weights.stat().st_mtime:
        exported = export_onnx(weights)
        if exported.resolve() != raw.resolve():
            raw.write_bytes(exported.read_bytes())
            exported.unlink()
    strip_postprocess(raw, dest)


if __name__ == "__main__":
    main()
