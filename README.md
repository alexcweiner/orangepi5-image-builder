# Orange Pi 5 image builder

Build a bootable microSD image for the **Orange Pi 5 (RK3588S, board revision
1.3.2)** with Armbian, Viam, and Rockchip NPU tools. Add your machine's Viam cloud
credentials before building so it can connect automatically on first boot.

The output is `out/orangepi5-viam-npu.img.xz` and its SHA-256 checksum.

## What goes on the card

- Armbian 26.8.1 / Debian 13 minimal with the vendor 6.1.115 kernel.
- Viam agent and server, installed from their stable channels.
- SSH, NetworkManager, and mDNS at `orangepi5.local`.
- Rockchip RKNN 2.3.2 and RKLLM runtimes, plus a Python 3.12 virtual environment.
- YOLOv8n detection, pose, and segmentation; FastSAM-s masks; and LightStereo-S depth models.
- InternVL3.5-1B with the `vlm-describe` tool for image captions and visual questions.
- Qwen2.5-1.5B-Instruct with the `llm-ask` tool for text prompts.

## Requirements

- The original Orange Pi 5 and a **32 GB or larger microSD card**.
- Ethernet and internet access for the Pi's first connection to Viam.
- Docker with a running daemon and support for privileged containers.
- At least **20 GB of free disk space**, with additional room for Docker's cache.

Build on Linux or Docker Desktop on macOS. The scripts support ARM64 and x86-64
Linux containers and register ARM64 emulation when needed.

## Prepare Viam cloud credentials

1. Create or choose a machine in [the Viam app](https://app.viam.com/).
2. Obtain its **machine cloud credentials** using
   [Viam's machine setup instructions](https://docs.viam.com/set-up-a-machine/).
3. Clone this project and create a local credentials file:

   ```sh
   git clone https://github.com/alexcweiner/orangepi5-image-builder.git
   cd orangepi5-image-builder
   cp rootfs/etc/viam.json.example viam.json
   chmod 600 viam.json
   ```

4. Open `viam.json` in your editor and paste the complete machine cloud credentials
   JSON from Viam. The supplied template shows the fields:

   ```json
   {
     "cloud": {
       "api_key": {
         "id": "REPLACE_WITH_CLOUD_API_KEY_ID",
         "key": "REPLACE_WITH_CLOUD_API_KEY"
       },
       "app_address": "https://app.viam.com:443",
       "id": "REPLACE_WITH_MACHINE_PART_ID",
       "secret": "REPLACE_WITH_MACHINE_PART_SECRET"
     }
   }
   ```

| Field | Value from the machine cloud credentials |
| --- | --- |
| `cloud.api_key.id` | API key ID. |
| `cloud.api_key.key` | Secret API key value paired with that ID. |
| `cloud.app_address` | Viam cloud endpoint, normally `https://app.viam.com:443`. |
| `cloud.id` | Machine **part ID**. |
| `cloud.secret` | Machine part secret. |

Use the complete machine cloud credentials document supplied by Viam, preserving
its fields. Git ignores your local `viam.json`.

## Build

From the project folder, run:

```sh
OPI_PASSWORD='choose-your-own-password' ./build.sh
```

The build automatically uses the local `viam.json`, validates it, and installs it
on the card as root-owned `/etc/viam.json` with mode `0600`. Viam agent is enabled
to start when the Pi boots. The build stops if the supplied credentials file has
invalid JSON, incomplete cloud credentials, or unchanged template placeholders.

The resulting `.img.xz` **contains your machine's credentials**. Keep it private
and use it for the intended machine.

The first build downloads several large models and compiles tools. Downloads are
cached in `cache/`, and converted models are reused from `out/models/`. You can
run either stage separately:

```sh
./build.sh models     # convert the NPU models
./build.sh image      # build the card image using existing out/models/
```

To use a credentials file elsewhere:

```sh
VIAM_CONFIG=/path/to/viam.json OPI_PASSWORD='choose-your-own-password' ./build.sh
```

`OPI_PASSWORD` sets the `opi` account's login password; its default is `orangepi`.

Verify the output after copying or downloading it:

```sh
cd out
shasum -a 256 -c orangepi5-viam-npu.img.xz.sha256
```

On Linux, you can also use `sha256sum -c orangepi5-viam-npu.img.xz.sha256`.

## Flash and boot

1. Flash `out/orangepi5-viam-npu.img.xz` with Raspberry Pi Imager or balenaEtcher.
   Flashing erases the selected card.
2. Insert the card into the Orange Pi, connect Ethernet, and power it on.
3. Check that the machine appears **Live** in the Viam app once the Pi has internet
   access. Configure your demo's components and services there.

Armbian expands the root filesystem to fill the card on first boot.

For troubleshooting, connect with `ssh opi@orangepi5.local` and the password set
at build time. Use the Pi's DHCP address if mDNS does not resolve. Check Viam's logs:

```sh
sudo journalctl -u viam-agent -n 50 --no-pager
```

## Use the NPU tools

The tools and models are installed under `/opt/orangepi-npu/`:

| Path | Contents |
| --- | --- |
| `bin/vlm-describe` | Image caption and visual question-answering CLI. |
| `bin/llm-ask` | Text-model CLI accepting requests on stdin. |
| `models/` | Converted RKNN and RKLLM weights. |
| `share/bus.jpg` | Sample image from Rockchip's YOLO example. |
| `venv/` | Python 3.12, RKNN Lite, NumPy, and OpenCV. |

On the Pi, describe the sample image:

```sh
cd /opt/orangepi-npu
bin/vlm-describe share/bus.jpg \
  models/internvl3_5-1b_vision_rk3588.rknn \
  models/internvl3_5-1b-instruct_w8a8_rk3588.rkllm \
  'Describe this picture in one sentence.' 96
```

Send a text prompt:

```sh
printf 'You are a helpful assistant.\tSay hello in one sentence.\n' | \
  bin/llm-ask models/Qwen2.5-1.5B-Instruct_RK3588_w8a8.rkllm 96
```

`llm-ask` reads one `<system><TAB><user>` request per line and emits marked replies.
Its fields escape backslash, newline, and tab as `\\`, `\n`, and `\t`.
Run one RKLLM model at a time on boards with limited memory. The RKLLM tools require
an rknpu driver version of at least 0.9.8; check it with
`sudo cat /sys/kernel/debug/rknpu/version` if inference fails.

## Repository layout

| File or directory | Purpose |
| --- | --- |
| `build.sh` | Starts the Docker containers and coordinates model conversion and image assembly. |
| `image/Dockerfile` | Installs the tools used by the image-building container. |
| `image/build-image.sh` | Downloads Armbian, mounts and customizes it, installs Viam and supplied credentials, then shrinks and compresses the disk image. |
| `image/customize-rootfs.sh` | Installs OS packages, NPU runtimes, Python, and compiled tools inside the ARM64 filesystem. |
| `image/partition.sh` | Grows and shrinks the image's GPT partitions and ext4 filesystem. |
| `image/convert-models.sh` | Downloads and converts the NPU models. |
| `image/*_rknn.py`, `image/fastsam_onnx.py` | Handle model conversion and FastSAM ONNX export. |
| `image/viam-config.py` | Validates and privately installs machine cloud credentials. |
| `image/config.env` | Sets base-image inputs, model revisions, runtime versions, hostname, and username. |
| `image/viam-defaults.json` | Sets Viam provisioning defaults. |
| `image/vlm/`, `image/llm/` | C++ entry points for the inference tools. |
| `rootfs/` | Files copied onto the card: NPU permissions, a shell PATH entry, and the Viam credentials example. |
| `tests/` | Launcher, credentials, payload, and partition checks. |

Docker provides the build environment. The scripts assemble the bootable disk
image inside a privileged container so they can mount and modify its partitions.

## Customize

- Edit [`image/config.env`](image/config.env) to change the configured inputs.
  Changing board models also requires checking kernel, NPU, and partition compatibility.
- Add your own files to [`rootfs/`](rootfs/) to include them on the card. Supply
  machine credentials through the local `viam.json` or `VIAM_CONFIG`.
- Use `VIAM_DEFAULTS=my-defaults.json ./build.sh image` to select a Viam provisioning
  defaults file inside the project folder.
- To make a generic image for later configuration, leave out the local `viam.json`
  and unset `VIAM_CONFIG`. The card includes `/etc/viam.json.example` as a starting point.

Viam stable channels, OS packages, and some Python dependencies resolve at build
time. Base-image and model versions and available checksums are recorded in
`image/config.env`.

## Development checks

```sh
python3 -m unittest discover -s tests -v
for script in build.sh image/*.sh tests/*.sh; do bash -n "$script" || exit; done
docker build -t orangepi5-image-builder image
docker run --rm --privileged --entrypoint bash -v "$PWD:/work:ro" \
  orangepi5-image-builder /work/tests/partition-smoke.sh
```

The Python checks exercise the launcher with a fake Docker executable, validate
credential handling, and check the card payload. The partition check grows and
shrinks a disposable disk image inside the container. Test a complete image build
and boot on the target board before relying on it.

## Upstream projects

The build downloads software and weights from these projects; their licenses apply:

- [Armbian](https://github.com/armbian/build)
- [Viam agent](https://github.com/viamrobotics/agent) and [Viam server](https://github.com/viamrobotics/rdk)
- [Rockchip RKNN Toolkit2](https://github.com/airockchip/rknn-toolkit2) and
  [RKNN Model Zoo](https://github.com/airockchip/rknn_model_zoo)
- [Ultralytics / FastSAM](https://github.com/ultralytics/ultralytics)
- [LightStereo RK3588 implementation](https://github.com/zz990099/lightstereo_cpp)
- [Qengineering InternVL NPU implementation](https://github.com/Qengineering/InternVL3.5-1B-NPU)
  and [converted weights](https://huggingface.co/Qengineering/InternVL3.5-1B-rk3588)
- [Converted Qwen2.5 weights](https://huggingface.co/HanzoHuang/Qwen2.5-1.5B-Instruct-RKLLM)
