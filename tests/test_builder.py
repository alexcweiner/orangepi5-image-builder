"""Exercise the host launcher without downloads, Docker, or root privileges."""
import json
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LauncherTests(unittest.TestCase):
    def run_launcher(self, *args, arch="aarch64", extra_env=None, local_config=None):
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
            env.pop("VIAM_CONFIG", None)
            env.update(extra_env or {})
            launcher = ROOT / "build.sh"
            if local_config is not None:
                project = tmp / "project"
                project.mkdir()
                launcher = project / "build.sh"
                launcher.write_text((ROOT / "build.sh").read_text())
                (project / "viam.json").write_text(local_config)
            result = subprocess.run(["bash", str(launcher), *args],
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

    def test_explicit_viam_config_is_mounted_read_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "viam.json"
            config.write_text('{"cloud": {}}')
            result, calls = self.run_launcher("image", extra_env={"VIAM_CONFIG": str(config)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("VIAM_CONFIG=/run/secrets/viam.json", calls[-1])
        self.assertIn(f"{config}:/run/secrets/viam.json:ro", calls[-1])

    def test_local_viam_json_is_used_automatically(self):
        result, calls = self.run_launcher("image", local_config='{"cloud": {}}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("VIAM_CONFIG=/run/secrets/viam.json", calls[-1])
        self.assertTrue(any(arg.endswith("/project/viam.json:/run/secrets/viam.json:ro")
                            for arg in calls[-1]))

    def test_missing_explicit_credentials_fail_before_model_downloads(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, calls = self.run_launcher("all", extra_env={"VIAM_CONFIG": str(Path(tmp) / "missing.json")})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_generic_image_does_not_get_credentials(self):
        result, calls = self.run_launcher("image")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("VIAM_CONFIG=" in arg for call in calls for arg in call))

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

    def test_rootfs_contains_only_generic_setup_and_viam_example(self):
        files = {p.relative_to(ROOT / "rootfs").as_posix()
                 for p in (ROOT / "rootfs").rglob("*") if p.is_file()}
        self.assertEqual(files, {"etc/udev/rules.d/99-rknpu.rules",
                                 "etc/profile.d/orangepi-npu.sh",
                                 "etc/viam.json.example"})

    def test_viam_example_has_only_placeholders_and_is_not_active(self):
        cloud = json.loads((ROOT / "rootfs/etc/viam.json.example").read_text())["cloud"]
        self.assertTrue(cloud["id"].startswith("REPLACE_WITH_"))
        self.assertTrue(cloud["secret"].startswith("REPLACE_WITH_"))
        self.assertTrue(cloud["api_key"]["id"].startswith("REPLACE_WITH_"))
        self.assertTrue(cloud["api_key"]["key"].startswith("REPLACE_WITH_"))
        self.assertEqual(cloud["app_address"], "https://app.viam.com:443")
        self.assertFalse((ROOT / "rootfs/etc/viam.json").exists())


class CredentialsTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("viam_config", ROOT / "image/viam-config.py")
        self.config = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.config)
        self.credentials = {"cloud": {"id": "test-part-id", "app_address": "https://app.viam.com:443",
                                      "secret": "test-only-part-secret",
                                      "api_key": {"id": "test-key-id", "key": "test-only-key"}}}

    def test_install_preserves_all_fields_and_private_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, destination = Path(tmp) / "source.json", Path(tmp) / "viam.json"
            source.write_text(json.dumps(self.credentials))
            destination.write_text("previous configuration")
            destination.chmod(0o644)
            self.config.install(source, destination)
            self.assertEqual(json.loads(destination.read_text()), self.credentials)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)

    def test_either_part_secret_or_api_key_can_authenticate(self):
        for omit in ("secret", "api_key"):
            with self.subTest(omit=omit), tempfile.TemporaryDirectory() as tmp:
                credentials = json.loads(json.dumps(self.credentials))
                del credentials["cloud"][omit]
                source = Path(tmp) / "source.json"
                source.write_text(json.dumps(credentials))
                self.assertEqual(self.config.validate(source), credentials)

    def test_invalid_credentials_do_not_replace_existing_configuration(self):
        cases = ['{"cloud":', '{}', '{"cloud": []}',
                 json.dumps({"cloud": {"id": "test", "app_address": "test"}}),
                 json.dumps({"cloud": {"id": "test", "app_address": "test", "api_key": {"id": "key"}}}),
                 (ROOT / "rootfs/etc/viam.json.example").read_text()]
        for contents in cases:
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as tmp:
                source, destination = Path(tmp) / "source.json", Path(tmp) / "viam.json"
                source.write_text(contents)
                destination.write_text("keep existing configuration")
                with self.assertRaises(ValueError):
                    self.config.install(source, destination)
                self.assertEqual(destination.read_text(), "keep existing configuration")

    def test_validation_does_not_log_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source.json"
            source.write_text(json.dumps(self.credentials))
            result = subprocess.run([sys.executable, str(ROOT / "image/viam-config.py"), "validate", str(source)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout + result.stderr, "")


if __name__ == "__main__":
    unittest.main()
