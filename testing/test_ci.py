import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]


class CiTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hadron-ci-")
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name) / "project with spaces"
        self.project.mkdir()
        for name in ("run-qemu.sh", "build-in-docker.sh", "ci/test-qemu-boot.sh"):
            source = REPOSITORY / name
            if source.exists():
                destination = self.project / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
        self.images = self.project / "build/tmp/deploy/images/hadron-ngx012"
        self.images.mkdir(parents=True)
        (self.images / "Image").touch()
        (self.images / "hadron-image-base-hadron-ngx012.rootfs.ext4").touch()
        self.bin = self.project / "bin"
        self.bin.mkdir()
        self.environment = os.environ.copy()
        self.environment.update(
            PATH=f"{self.bin}:{self.environment['PATH']}",
            HADRON_QEMU_LOGS=str(self.project / "logs"),
            TEST_ROOT=str(self.project),
        )
        qemu = self.bin / "qemu-system-aarch64"
        qemu.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, signal, sys, time\n"
            "root = pathlib.Path(os.environ['TEST_ROOT'])\n"
            "(root / 'args.json').write_text(json.dumps(sys.argv[1:]))\n"
            "(root / 'pid').write_text(str(os.getpid()))\n"
            "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\n"
            "mode = os.environ.get('TEST_MODE', 'args')\n"
            "if mode == 'args': sys.exit(0)\n"
            "if mode == 'exit': sys.exit(7)\n"
            "serial = sys.argv[sys.argv.index('-chardev') + 1]\n"
            "log = pathlib.Path(serial.split('logfile=', 1)[1])\n"
            "if mode == 'prompt':\n"
            "    log.write_text('Booting\\nhadron-ngx012 log')\n"
            "    time.sleep(0.1)\n"
            "    with log.open('a') as stream: stream.write('in: ')\n"
            "elif mode == 'panic':\n"
            "    log.write_text('Kernel panic - not syncing: test\\n')\n"
            "else: log.write_text('Booting\\n')\n"
            "while True: time.sleep(1)\n"
        )
        qemu.chmod(0o755)

    def run_script(self, name, *arguments):
        self.assertTrue((self.project / name).exists(), f"Missing {name}")
        return subprocess.run(
            ["bash", str(self.project / name), *arguments],
            cwd=self.temporary.name,
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_launcher_resolves_checkout_and_keeps_snapshot(self):
        import json

        result = self.run_script("run-qemu.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads((self.project / "args.json").read_text())
        self.assertEqual(arguments[arguments.index("-kernel") + 1],
                         str(self.images / "Image"))
        drive = arguments[arguments.index("-drive") + 1]
        self.assertIn(f"file={self.images}/hadron-image-base-hadron-ngx012.rootfs.ext4", drive)
        self.assertIn("snapshot=on", drive)

    def test_launcher_rejects_missing_artifacts_before_qemu(self):
        for artifact, message in (
            ("Image", "Image not found"),
            ("hadron-image-base-hadron-ngx012.rootfs.ext4", "Rootfs not found"),
        ):
            with self.subTest(artifact=artifact):
                path = self.images / artifact
                path.unlink()
                result = self.run_script("run-qemu.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse((self.project / "args.json").exists())
                path.touch()

    def test_boot_prompt_failures_and_cleanup(self):
        for mode, status, message in (
            ("prompt", 0, "PASS"),
            ("panic", 1, "Kernel panic"),
            ("exit", 1, "exited"),
            ("timeout", 1, "Timed out"),
        ):
            with self.subTest(mode=mode):
                stale = self.project / "logs/console.log"
                stale.parent.mkdir(exist_ok=True)
                stale.write_text("hadron-ngx012 login: ")
                self.environment["TEST_MODE"] = mode
                result = self.run_script("ci/test-qemu-boot.sh", "2")
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertIn(message, result.stdout + result.stderr)
                pid = int((self.project / "pid").read_text())
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)

    def test_boot_rejects_invalid_timeout(self):
        for timeout in ("0", "-1", "abc"):
            with self.subTest(timeout=timeout):
                result = self.run_script("ci/test-qemu-boot.sh", timeout)
                self.assertEqual(result.returncode, 2)
                self.assertFalse((self.project / "pid").exists())

    def test_docker_build_noninteractive_mounts_and_exit_status(self):
        docker = self.bin / "docker"
        docker.write_text(
            '#!/bin/sh\n'
            'if [ "$1" = run ]; then\n'
            '  printf "%s\\n" "$@"\n'
            '  exit "${TEST_DOCKER_STATUS:-0}"\n'
            'fi\n'
        )
        docker.chmod(0o755)
        self.environment.update(
            HADRON_DL_CACHE=str(self.project),
            HADRON_SSTATE_CACHE=str(self.project),
        )
        result = self.run_script("build-in-docker.sh", "--target", "hadron-image-desktop")
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = result.stdout.splitlines()
        self.assertIn(f"{self.project}:{self.project}", arguments)
        self.assertIn(f"{self.project}:/media/ranshal/jetson/shared/downloads", arguments)
        self.assertIn(f"{self.project}:/media/ranshal/jetson/shared/sstate", arguments)
        self.assertEqual(arguments[arguments.index("-w") + 1], str(self.project))
        self.assertNotIn("-it", arguments)
        self.assertEqual(arguments[arguments.index("kas"):],
                         ["kas", "build", "kas.yml", "--target", "hadron-image-desktop"])
        self.environment["TEST_DOCKER_STATUS"] = "7"
        result = self.run_script("build-in-docker.sh")
        self.assertEqual(result.returncode, 7)


if __name__ == "__main__":
    unittest.main()
