#!/usr/bin/env python3
"""Exercise real entry points with harmless command bodies and kernel file locks."""
import fcntl
import os
from pathlib import Path
import pty
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
MUTATIONS = ("install", "update", "uninstall", "config", "restart", "self-update")

STUBS = r'''
ensure_root() { :; }
resolve_psk_source() { :; }
menu_status_line() { :; }
pause() { echo TEST_PAUSE; read -r unused; }
test_operation() {
    if { : >&9; } 2>/dev/null; then
        echo "operation inherited lock descriptor" >&2
        exit 91
    fi
    echo "RUN:$1"
    case "${TEST_ACTION:-success}" in
        block)
            while [[ ! -e "$TEST_GATE" ]]; do sleep 0.02; done
            ;;
        fail) false; echo UNREACHABLE ;;
        die) exit 23 ;;
        cancel) return 0 ;;
        background)
            sleep 30 >/dev/null 2>&1 &
            echo "$!" >"$TEST_CHILD"
            ;;
        temp|temp-fail)
            ensure_tmp_dir
            echo "$TMP_DIR" >"$TEST_TEMP"
            [[ "$TEST_ACTION" != temp-fail ]] || exit 24
            ;;
    esac
}
cmd_install() { test_operation install; }
cmd_update() { test_operation update; }
cmd_uninstall() { test_operation uninstall; }
cmd_config() { test_operation config; }
cmd_restart() { test_operation restart; }
cmd_self_update() { test_operation self-update; }
cmd_show() { test_operation show; }
cmd_log() { test_operation log; }
cmd_status() { test_operation status; }
main "$@"
'''


class LockingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="snell-lock-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.lock = self.base / "operation.lock"
        self.gate = self.base / "gate"
        self.env = dict(os.environ, TEST_LOCK_FILE=str(self.lock),
                        TEST_GATE=str(self.gate),
                        TEST_CHILD=str(self.base / "child"),
                        TEST_TEMP=str(self.base / "temp"), NO_COLOR="1")
        source = (ROOT / "snell.sh").read_text()
        self.assertTrue(source.endswith('main "$@"\n'))
        source = source.rsplit('main "$@"', 1)[0]
        original = 'readonly LOCK_FILE="/run/snell-sh.lock"'
        self.assertEqual(source.count(original), 1)
        source = source.replace(original, 'readonly LOCK_FILE="${TEST_LOCK_FILE:?}"')
        self.script = self.base / "fixture.sh"
        self.script.write_text(source + STUBS)

    def cli(self, command, action="success", **env):
        return subprocess.run([BASH, str(self.script), command],
                              env=dict(self.env, TEST_ACTION=action, **env),
                              stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, timeout=5)

    def start(self, command="menu", action="success"):
        master, slave = pty.openpty()
        log = tempfile.TemporaryFile()
        process = subprocess.Popen([BASH, str(self.script), command], stdin=slave,
                                   stdout=log, stderr=log, start_new_session=True,
                                   env=dict(self.env, TEST_ACTION=action))
        os.close(slave)

        def cleanup():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
            os.close(master)
            log.close()
        self.addCleanup(cleanup)
        return process, master, log

    def output(self, log):
        return os.pread(log.fileno(), 100000, 0).decode()

    def await_output(self, log, text):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if text in self.output(log):
                return
            time.sleep(0.02)
        self.fail(f"missing {text!r}: {self.output(log)}")

    def assert_unlocked(self):
        with self.lock.open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_two_idle_menus_and_cli(self):
        for _ in range(2):
            process, _, log = self.start()
            self.await_output(log, "请选择 [0-8]")
            self.assertIsNone(process.poll())
        self.assert_unlocked()
        self.assertEqual(self.cli("install").returncode, 0)

    def test_conflicts_block_every_mutation_but_allow_reads_and_menu(self):
        with self.lock.open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for command in MUTATIONS:
                with self.subTest(command=command):
                    result = self.cli(command)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("正在修改系统", result.stderr)
                    self.assertNotIn("RUN:", result.stdout)
            for command in ("show", "log", "status"):
                result = self.cli(command)
                self.assertEqual(result.returncode, 0, result.stderr)
            process, master, log = self.start()
            self.await_output(log, "请选择 [0-8]")
            os.write(master, b"4\n")
            self.await_output(log, "RUN:show")
            self.assertIsNone(process.poll())

    def test_concurrent_operations_and_release(self):
        process, _, log = self.start("install", "block")
        self.await_output(log, "RUN:install")
        result = self.cli("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("正在修改系统", result.stderr)
        self.gate.touch()
        self.assertEqual(process.wait(timeout=5), 0)
        self.assert_unlocked()
        self.assertEqual(self.cli("update").returncode, 0)

    def test_menu_releases_before_pause_for_all_mutations(self):
        for choice in (1, 2, 3, 5, 7, 8):
            with self.subTest(choice=choice):
                process, master, log = self.start()
                self.await_output(log, "请选择 [0-8]")
                os.write(master, f"{choice}\n".encode())
                self.await_output(log, "TEST_PAUSE")
                self.assertNotIn("inherited", self.output(log))
                self.assertNotIn("操作未成功", self.output(log))
                self.assertIsNone(process.poll())
                self.assert_unlocked()
                self.assertEqual(self.cli("install").returncode, 0)
                os.write(master, b"\n0\n")
                self.assertEqual(process.wait(timeout=5), 0)

    def test_failure_exit_and_cancel_release_without_disabling_errexit(self):
        for action, status in (("fail", 1), ("die", 23), ("cancel", 0)):
            with self.subTest(action=action):
                result = self.cli("install", action)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertNotIn("UNREACHABLE", result.stdout)
                self.assert_unlocked()
                process, master, log = self.start(action=action)
                self.await_output(log, "请选择 [0-8]")
                os.write(master, b"1\n")
                self.await_output(log, "TEST_PAUSE")
                self.assertNotIn("UNREACHABLE", self.output(log))
                if status:
                    self.assertIn(f"退出码 {status}", self.output(log))
                self.assertIsNone(process.poll())
                self.assert_unlocked()
                os.write(master, b"\n0\n")
                self.assertEqual(process.wait(timeout=5), 0)

    def test_menu_can_retry_after_conflict(self):
        process, master, log = self.start()
        self.await_output(log, "请选择 [0-8]")
        with self.lock.open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            os.write(master, b"1\n")
            self.await_output(log, "TEST_PAUSE")
            self.assertNotIn("RUN:install", self.output(log))
        os.write(master, b"\n1\n")
        self.await_output(log, "RUN:install")
        os.write(master, b"\n0\n")
        self.assertEqual(process.wait(timeout=5), 0)

    def test_background_child_does_not_keep_lock(self):
        result = self.cli("install", "background")
        self.assertEqual(result.returncode, 0, result.stderr)
        pid = int((self.base / "child").read_text())
        self.addCleanup(os.kill, pid, signal.SIGKILL)
        os.kill(pid, 0)
        self.assert_unlocked()
        self.assertEqual(self.cli("update").returncode, 0)

    def test_operation_temp_directory_is_cleaned_on_success_and_failure(self):
        for action, status in (("temp", 0), ("temp-fail", 24)):
            result = self.cli("self-update", action)
            self.assertEqual(result.returncode, status, result.stderr)
            path = Path((self.base / "temp").read_text().strip())
            self.assertFalse(path.exists())
            self.assert_unlocked()

    def test_unusable_lock_file_aborts_without_running_operation(self):
        result = self.cli("install", TEST_LOCK_FILE=str(self.base / "missing" / "lock"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("无法打开锁文件", result.stderr)
        self.assertNotIn("RUN:", result.stdout)

    def test_missing_flock_aborts_mutations_but_allows_reads(self):
        result = self.cli("install", PATH=str(self.base))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("缺少 flock", result.stderr)
        self.assertNotIn("RUN:", result.stdout)
        self.assertEqual(self.cli("show", PATH=str(self.base)).returncode, 0)

    def test_terminated_operation_releases_lock(self):
        process, _, log = self.start("install", "block")
        self.await_output(log, "RUN:install")
        os.killpg(process.pid, signal.SIGTERM)
        self.assertNotEqual(process.wait(timeout=5), 0)
        # The waiting shell may finish a little later than the main entry process.
        deadline = time.monotonic() + 5
        while True:
            try:
                self.assert_unlocked()
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.02)
        self.assertEqual(self.cli("update").returncode, 0)


if __name__ == "__main__":
    if not BASH or not shutil.which("flock"):
        raise SystemExit("Tests require bash and flock (util-linux on Linux).")
    unittest.main()
