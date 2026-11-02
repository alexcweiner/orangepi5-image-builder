"""Exercise the host launcher without downloads, Docker, or root privileges."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LauncherTests(unittest.TestCase):
    def run_launcher(self, *args, arch="aarch64"):
        with tempfile.TemporaryDirectory(prefix="builder test ") as tmp:
            tmp = Path(tmp)
            docker = tmp / "docker"
            docker.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                "with open(os.environ['DOCKER_LOG'], 'a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "if sys.argv[1] == 'info': print(os.environ['DOCKER_ARCH'])\n"
            )
            docker.chmod(0o755)
            log = tmp / "calls.jsonl"
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}",
                       DOCKER_LOG=str(log), DOCKER_ARCH=arch)
            env.pop("VIAM_DEFAULTS", None)
            env.pop("OPI_PASSWORD", None)
            result = subprocess.run(["bash", str(ROOT / "build.sh"), *args],
                                    cwd=tmp, env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_default_converts_models_before_building_image(self):
        result, calls = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        conversion = next(i for i, call in enumerate(calls) if "python:3.11-slim" in call)
        build = next(i for i, call in enumerate(calls) if call[0] == "build")
        self.assertLess(conversion, build)
        self.assertIn(f"{ROOT}:/work", calls[conversion])
        self.assertIn("linux/arm64", calls[conversion])

    def test_image_only_on_arm64_skips_conversion_and_emulation(self):
        result, calls = self.run_launcher("image")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("python:3.11-slim" in c or "tonistiigi/binfmt" in c for c in calls))
        self.assertIn("--privileged", calls[-1])
        self.assertIn(f"{ROOT}:/work", calls[-1])
        self.assertIn("/dev:/dev", calls[-1])

    def test_x86_host_registers_arm64_before_image_build(self):
        result, calls = self.run_launcher("image", arch="x86_64")
        self.assertEqual(result.returncode, 0, result.stderr)
        emulator = next(i for i, call in enumerate(calls) if "tonistiigi/binfmt" in call)
        build = next(i for i, call in enumerate(calls) if call[0] == "build")
        self.assertLess(emulator, build)

    def test_models_only_never_starts_privileged_builder(self):
        result, calls = self.run_launcher("models", arch="x86_64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("linux/amd64", calls[-1])
        self.assertFalse(any("--privileged" in c or c[0] == "build" for c in calls))

    def test_invalid_step_exits_before_running_docker(self):
        result, calls = self.run_launcher("invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage:", result.stderr)
        self.assertEqual(calls, [])


class PayloadTests(unittest.TestCase):
    def test_standalone_image_has_no_robot_runtime_dependencies(self):
        customize = (ROOT / "image/customize-rootfs.sh").read_text()
        build = (ROOT / "image/build-image.sh").read_text()
        self.assertIn('"$ROOT/rootfs/"', build)
        self.assertIn("/opt/orangepi-npu/bin/vlm-describe", customize)
        self.assertIn("/opt/orangepi-npu/models", build)
        for text in (customize, build, (ROOT / "image/config.env").read_text()):
            for forbidden in ("/opt/opi-bot", "opibot", "REBOT_", "motorbridge",
                              "opi-bot-core.service", "viam-gateway", "dashboard"):
                self.assertNotIn(forbidden, text)

    def test_rootfs_contains_only_generic_npu_setup(self):
        files = {p.relative_to(ROOT / "rootfs").as_posix()
                 for p in (ROOT / "rootfs").rglob("*") if p.is_file()}
        self.assertEqual(files, {"etc/udev/rules.d/99-rknpu.rules",
                                 "etc/profile.d/orangepi-npu.sh"})


if __name__ == "__main__":
    unittest.main()
