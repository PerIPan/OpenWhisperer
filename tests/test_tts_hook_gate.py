import json
import subprocess
from pathlib import Path

HOOK = Path(__file__).resolve().parents[1] / "hooks" / "tts-hook.sh"


def run(input_obj, home):
    appdir = home / "Library" / "Application Support" / "OpenWhisperer"
    appdir.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        [str(HOOK)], input=json.dumps(input_obj), capture_output=True, text=True,
        env={"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/local/bin",
             "TTS_URL": "http://localhost:1/v1/audio/speech"},  # unreachable
        timeout=20,
    )
    return proc, appdir


def test_no_marker_exits_without_locking(tmp_path):
    proc, appdir = run({"session_id": "s1", "last_assistant_message": "Hi there."}, tmp_path)
    assert proc.returncode == 0
    assert not (appdir / "tts_hook.lockdir").exists()   # never acquired the lock
    assert not (appdir / "tts_hook.pid").exists()


def test_marker_consumed_when_present(tmp_path):
    appdir = tmp_path / "Library" / "Application Support" / "OpenWhisperer"
    (appdir / "speak_pending").mkdir(parents=True)
    (appdir / "speak_pending" / "s1").touch()
    proc, appdir = run({"session_id": "s1", "last_assistant_message": "Done and verified."}, tmp_path)
    assert proc.returncode == 0
    assert not (appdir / "speak_pending" / "s1").exists()   # marker consumed


def test_stop_hook_active_is_ignored(tmp_path):
    proc, appdir = run({"stop_hook_active": True, "session_id": "s1",
                        "last_assistant_message": "x"}, tmp_path)
    assert proc.returncode == 0
    assert not (appdir / "tts_hook.lockdir").exists()
