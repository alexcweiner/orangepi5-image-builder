# Orange Pi 5 image builder

Build a bootable microSD image for the **original Orange Pi 5 (RK3588S)** using Docker.
The output is `out/orangepi5-viam-npu.img.xz` and its SHA-256 checksum.

This is the standalone image-building portion of a robot project. It includes the
OS setup, Viam installation, and NPU model tools. The robot application, arm driver,
dashboard, calibration data, and robot services are excluded. No Viam credentials
are included. The image does not start a camera loop or inference server.

## What goes on the card

- Armbian 26.8.1 / Debian 13 minimal, with the vendor 6.1.115 kernel for Rockchip NPU support.
- SSH, NetworkManager, and mDNS (`orangepi5.local`).
- Viam agent and server, downloaded from their stable channels during the build.
- Rockchip RKNN 2.3.2 and RKLLM runtimes, plus a Python 3.12 virtual environment.
- YOLOv8n detection, pose, and segmentation; FastSAM-s; and LightStereo-S models.
- InternVL3.5-1B vision/language models and the `vlm-describe` command-line tool.
- Qwen2.5-1.5B-Instruct and the `llm-ask` command-line tool.

This targets the original Orange Pi 5, board revision 1.3.2. Other boards such as
the 5 Plus, Pro, Max, 5B, and Ultra need a different base image and are not covered.

## Build

You need Docker with a running daemon, internet access, and at least 20 GB of free
disk space; allow more for Docker's cache and temporary files. On macOS, use Docker
Desktop with Linux containers. The scripts support native ARM64 and x86-64 Linux
containers, and register ARM64 emulation when needed. The image step runs a
**privileged container** to mount the image through loop devices. Rootless Docker
and environments that disallow privileged containers are not supported.

```sh
git clone https://github.com/alexcweiner/orangepi5-image-builder.git
cd orangepi5-image-builder
OPI_PASSWORD='choose-your-own-password' ./build.sh
```

The first build downloads several large model files and compiles tools. Downloads
are reused from `cache/`, and converted models are reused from `out/models/`.

```sh
./build.sh models     # only convert the NPU models
./build.sh image      # only build the card image; requires out/models/ first
```

If `OPI_PASSWORD` is omitted, the image's `opi` account password is `orangepi`.
The password is baked into the resulting card image, so set your own before
sharing or using it. Root password login is locked.

Check the output after copying or downloading it:

```sh
cd out
shasum -a 256 -c orangepi5-viam-npu.img.xz.sha256
```

Linux users can use `sha256sum -c` instead of `shasum -a 256 -c`.

## Flash and boot

1. Flash `out/orangepi5-viam-npu.img.xz` to a **32 GB or larger microSD card** with
   Raspberry Pi Imager or balenaEtcher. Flashing erases the selected card.
2. Insert it into the Orange Pi and boot with Ethernet connected. The original
   Orange Pi 5 has no onboard Wi-Fi; Viam Wi-Fi/Bluetooth provisioning is disabled.
3. Connect with `ssh opi@orangepi5.local`, using the password chosen at build time.
   Use the board's DHCP address if mDNS does not resolve.

Armbian expands the root filesystem to fill the card on first boot. Configure
the machine in Viam separately; the build deliberately excludes `/etc/viam.json`.

## Use the NPU tools

Everything specific to the NPU tools is under `/opt/orangepi-npu/`:

| Path | Contents |
| --- | --- |
| `bin/vlm-describe` | Image caption / visual question-answering CLI |
| `bin/llm-ask` | Text-model CLI; accepts requests on stdin |
| `models/` | Converted RKNN and RKLLM weights |
| `share/bus.jpg` | Sample image from Rockchip's YOLO example |
| `venv/` | Python 3.12, RKNN Lite, NumPy, and OpenCV |

For example, on the board:

```sh
cd /opt/orangepi-npu
bin/vlm-describe share/bus.jpg \
  models/internvl3_5-1b_vision_rk3588.rknn \
  models/internvl3_5-1b-instruct_w8a8_rk3588.rkllm \
  'Describe this picture in one sentence.' 96

printf 'You are a helpful assistant.\tSay hello in one sentence.\n' | \
  bin/llm-ask models/Qwen2.5-1.5B-Instruct_RK3588_w8a8.rkllm 96
```

`llm-ask` reads one `<system><TAB><user>` request per line and emits marked replies.
Its fields escape backslash, newline, and tab as `\\`, `\n`, and `\t`.
Only run one RKLLM model at a time on a board with limited memory. The RKLLM tools
need an rknpu driver version of at least 0.9.8; inspect it with
`sudo cat /sys/kernel/debug/rknpu/version` if inference fails.

The vision weights are ready for your own application. A camera application,
stereo calibration, YOLO postprocessing, and a custom Viam module are not bundled.

## Customize

- [`image/config.env`](image/config.env) sets the base image URL/checksum, model
  revisions, NPU runtime version, hostname, and username. Changing board models
  requires checking kernel, NPU, and partition compatibility too.
- [`rootfs/`](rootfs/) is a minimal filesystem overlay containing NPU permissions
  and a shell PATH entry. Put your own non-secret files here to copy them onto the card.
- [`image/customize-rootfs.sh`](image/customize-rootfs.sh) installs packages and
  compiles the command-line tools inside the ARM64 filesystem.
- [`image/viam-defaults.json`](image/viam-defaults.json) contains generic Viam
  provisioning defaults. To use a local replacement, place it inside this checkout
  and run `VIAM_DEFAULTS=my-defaults.json ./build.sh image`. Do not commit credentials.

The base image and model revisions/checksums are configured in `image/config.env`.
This is **not a fully reproducible build**: Viam uses stable channels, apt and some
Python dependencies resolve at build time, and not every download has a checksum.
If an upstream URL disappears, update its URL and verify a replacement checksum.

## Repository layout

```text
build.sh                   Host entry point: models, image, or both
image/Dockerfile           Ubuntu build environment
image/build-image.sh       Download, mount, customize, shrink, compress
image/partition.sh         GPT/ext4 grow and shrink helpers
image/convert-models.sh    RK3588 model conversion
image/*_rknn.py            Conversion helpers
image/fastsam_onnx.py      FastSAM ONNX export helper
image/vlm/, image/llm/     Standalone C++ inference entry points
rootfs/                   Minimal NPU setup overlay
tests/                    Launcher, payload, and partition checks
```

The builder starts from Armbian, expands and mounts the root partition, copies in
the overlay and models, customizes it in an ARM64 chroot, installs Viam, then
shrinks and compresses the image. This builds a disk image, not an ISO or a
container intended to run on the board.

## Development checks

```sh
python3 -m unittest discover -s tests -v
for script in build.sh image/*.sh tests/*.sh; do bash -n "$script" || exit; done
docker build -t orangepi5-image-builder image
docker run --rm --privileged --entrypoint bash -v "$PWD:/work:ro" \
  orangepi5-image-builder /work/tests/partition-smoke.sh
```

The Python checks use a fake Docker executable and do not download models. The
partition check creates and removes a small disposable image inside the container;
it never selects a physical disk. These checks do not replace a full image build
and a boot/inference test on the target board.

## Upstream projects

The build downloads third-party software and weights; their licenses still apply:

- [Armbian](https://github.com/armbian/build)
- [Viam agent](https://github.com/viamrobotics/agent) and [Viam server](https://github.com/viamrobotics/rdk)
- [Rockchip RKNN Toolkit2](https://github.com/airockchip/rknn-toolkit2) and
  [RKNN Model Zoo](https://github.com/airockchip/rknn_model_zoo)
- [Ultralytics / FastSAM](https://github.com/ultralytics/ultralytics)
- [LightStereo RK3588 implementation](https://github.com/zz990099/lightstereo_cpp)
- [Qengineering InternVL NPU implementation](https://github.com/Qengineering/InternVL3.5-1B-NPU)
  and [converted weights](https://huggingface.co/Qengineering/InternVL3.5-1B-rk3588)
- [Converted Qwen2.5 weights](https://huggingface.co/HanzoHuang/Qwen2.5-1.5B-Instruct-RKLLM)
