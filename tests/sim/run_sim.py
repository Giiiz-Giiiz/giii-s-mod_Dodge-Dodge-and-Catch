#!/usr/bin/env python3
"""Play scripted sessions in the GiiiCon PC simulator (same Lua runtime as the device).

Each scenario writes a sensor recording (`t_us sensor x y z w`, accel=1 gyro=2) and an
input replay (`t_us type a b handle`), runs `giii sim`, and checks the app's log lines.
Simulated sensors are not a hardware gyro test (Issue #3); they check the app's wiring.

    python3 tests/sim/run_sim.py [--giiicon ../GiiiCon] [--shots docs/screens]
"""

from __future__ import annotations

import argparse
import math
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
G = 9.80665
STEP_US = 16667
EVT_BACKGROUND, EVT_FOREGROUND, EVT_INPUT = 3, 2, 65
POINTER, DOWN, MOVE, UP = 2, 1, 2, 3


def up_for(roll: float, pitch: float = 0.0) -> tuple[float, float, float]:
    """Accelerometer reading for a device rolled right / pitched bottom-down (degrees)."""
    r, p = math.radians(roll), math.radians(pitch)
    x, y, z = -math.sin(r), 0.0, math.cos(r)
    y, z = y * math.cos(p) + z * math.sin(p), -y * math.sin(p) + z * math.cos(p)
    return x * G, y * G, z * G


class Session:
    def __init__(self) -> None:
        self.sensors: list[tuple[int, int, float, float, float]] = []
        self.events: list[tuple[int, int, int, int]] = []

    def imu(self, t0: float, t1: float, roll=lambda t: 0.0, rate=lambda t: (0.0, 0.0, 0.0)):
        """100 Hz accel+gyro from t0 to t1 seconds; roll(t) degrees, rate(t) rad/s."""
        t = t0
        while t < t1:
            us = int(round(t * 1e6))
            self.sensors.append((us, 1, *up_for(roll(t))))
            self.sensors.append((us, 2, *rate(t)))
            t += 0.01

    def tap(self, t: float, x: int, y: int) -> None:
        us = int(t * 1e6)
        xy = (x & 0xFFFF) | ((y & 0xFFFF) << 16)
        self.events.append((us, EVT_INPUT, POINTER | (DOWN << 8), xy))
        self.events.append((us + 50000, EVT_INPUT, POINTER | (UP << 8), xy))

    def drag(self, t0: float, t1: float, x: int, y: int) -> None:
        xy = (x & 0xFFFF) | ((y & 0xFFFF) << 16)
        self.events.append((int(t0 * 1e6), EVT_INPUT, POINTER | (DOWN << 8), xy))
        t = t0 + 0.1
        while t < t1:
            self.events.append((int(t * 1e6), EVT_INPUT, POINTER | (MOVE << 8), xy))
            t += 0.1
        self.events.append((int(t1 * 1e6), EVT_INPUT, POINTER | (UP << 8), xy))

    def lifecycle(self, t: float, kind: int) -> None:
        self.events.append((int(t * 1e6), kind, 0, 0))


class Runner:
    def __init__(self, giiicon: Path, shots: Path | None) -> None:
        self.giiicon = giiicon
        self.shots = shots
        self.tmp = Path(tempfile.mkdtemp(prefix="ddc-sim-"))
        self.failures = 0

    def giii(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["uv", "run", "--quiet", "--project", str(self.giiicon / "tools"), "giii", *args],
            cwd=self.giiicon,
            capture_output=True,
            text=True,
            check=False,
        )

    def build(self) -> None:
        r = self.giii("build", str(ROOT / "app"))
        if r.returncode != 0:
            sys.exit(f"build failed:\n{r.stdout}{r.stderr}")

    def run(self, name: str, s: Session, secs: float, storage: str | None = None,
            seed: int = 7) -> str:
        sensors = self.tmp / f"{name}.sensors"
        replay = self.tmp / f"{name}.replay"
        sensors.write_text("".join(f"{t} {k} {x:.5f} {y:.5f} {z:.5f} 0\n" for t, k, x, y, z in sorted(s.sensors, key=lambda r: r[0])))
        replay.write_text("".join(f"{t} {k} {a} {b} 0\n" for t, k, a, b in sorted(s.events)))
        screen = self.tmp / f"{name}.ppm"
        args = ["sim", str(ROOT / "app"), "--frames", str(int(secs * 1e6 / STEP_US)),
                "--step-us", str(STEP_US), "--seed", str(seed), "--screen", str(screen),
                "--storage", str(self.tmp / (storage or name)), "--profile"]
        if s.sensors:
            args += ["--sensors", str(sensors)]
        if s.events:
            args += ["--replay", str(replay)]
        r = self.giii(*args)
        out = r.stdout + r.stderr
        if r.returncode != 0:
            self.fail(name, f"simulator exit {r.returncode}\n{out[-2000:]}")
        if self.shots:
            self.shots.mkdir(parents=True, exist_ok=True)
            subprocess.run([sys.executable, str(ROOT / "scripts/ppm2png.py"), str(screen),
                            str(self.shots / f"{name}.png"), "2"], check=True)
        return out

    def fail(self, name: str, why: str) -> None:
        self.failures += 1
        print(f"FAIL {name}: {why}")

    def check(self, name: str, cond: bool, why: str, out: str) -> None:
        if not cond:
            self.fail(name, why + "\n--- log tail ---\n" + "\n".join(out.splitlines()[-25:]))


def stats(out: str) -> list[dict[str, float]]:
    rows = []
    for m in re.finditer(r"^STAT (.*)$", out, re.M):
        rows.append({k: float(v) for k, v in re.findall(r"(\w+)=([-\d.]+)", m.group(1))})
    return rows


def calibrated_start(s: Session) -> None:
    """Still device -> calibration -> tap Start -> 3 s countdown (play from ~4.6 s)."""
    s.imu(0.0, 1.5)
    s.tap(1.5, 160, 114)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--giiicon", default=str(ROOT.parent / "GiiiCon"))
    ap.add_argument("--shots", help="write PNG screenshots of each scenario here")
    a = ap.parse_args()
    r = Runner(Path(a.giiicon).resolve(), Path(a.shots).resolve() if a.shots else None)
    r.build()

    # 1. title after calibration
    s = Session()
    s.imu(0.0, 2.0)
    out = r.run("title", s, 2.0)
    r.check("title", "CALIBRATED" in out and "STATE title" in out, "calibrates when still", out)

    # 2. tilting right flies right, back to neutral stops (play starts at ~4.55 s,
    #    STAT lines every second of play: tick 60 = 5.55 s, 120 = 6.55 s, ...)
    s = Session()
    calibrated_start(s)
    s.imu(1.5, 6.0)
    # roll 0 -> 15 deg over 0.2 s (the gyro reports the same motion), hold, back to 0
    s.imu(6.0, 6.2, roll=lambda t: (t - 6.0) / 0.2 * 15,
          rate=lambda t: (0.0, math.radians(15) / 0.2, 0.0))
    s.imu(6.2, 7.5, roll=lambda t: 15)
    s.imu(7.5, 7.7, roll=lambda t: 15 - (t - 7.5) / 0.2 * 15,
          rate=lambda t: (0.0, -math.radians(15) / 0.2, 0.0))
    s.imu(7.7, 9.0)
    out = r.run("tilt_right", s, 9.0)
    rows = stats(out)
    r.check("tilt_right", "STATE play" in out, "reaches play", out)
    at = {round(row["tick"] / 60): row for row in rows}
    r.check("tilt_right", 1 in at and abs(at[1]["ux"]) < 0.05, "still before the tilt", out)
    r.check("tilt_right", 2 in at and at[2]["ux"] > 0.5, "tilted right -> positive input", out)
    r.check("tilt_right", 2 in at and at[2]["x"] > 175, "ship moved right", out)
    r.check("tilt_right", 4 in at and abs(at[4]["ux"]) < 0.05, "back to neutral -> stops", out)
    r.check("tilt_right", 4 in at and abs(at[4]["x"] - at[3]["x"]) < 20, "and stays", out)

    # 3. the gyro going silent pauses the game instead of flying on
    s = Session()
    calibrated_start(s)
    s.imu(1.5, 6.0)
    out = r.run("sensor_stop", s, 7.0)
    r.check("sensor_stop", "PAUSE sensor stale" in out, "stale samples pause the run", out)

    # 4. HOME / background pauses, foreground stays paused until Resume
    s = Session()
    calibrated_start(s)
    s.imu(1.5, 9.0)
    s.lifecycle(5.5, EVT_BACKGROUND)
    s.lifecycle(6.0, EVT_FOREGROUND)
    s.tap(7.0, 160, 97)  # Resume
    out = r.run("background", s, 9.0)
    idx_pause = out.find("STATE pause")
    r.check("background", idx_pause >= 0, "background pauses", out)
    r.check("background", out.find("STATE countdown", idx_pause) > idx_pause,
            "resume goes through the countdown", out)

    # 5. no samples at all -> skip -> touch alternative, ship follows the finger
    s = Session()
    s.tap(4.5, 160, 120)  # skip calibration
    s.tap(5.0, 160, 114)  # Start
    s.drag(8.5, 10.5, 60, 200)
    out = r.run("touch", s, 11.0)
    rows = stats(out)
    r.check("touch", "imu=no samples" in out and "mode=touch" in out, "falls back to touch", out)
    r.check("touch", bool(rows) and rows[-1]["x"] < 120, "ship followed the finger left", out)

    # 6. a full run ends, the best score is saved and reproduces with the same seed
    def full_run(storage: str) -> str:
        s = Session()
        calibrated_start(s)
        s.imu(1.5, 120.0)
        return r.run("over", s, 120.0, storage=storage, seed=11)

    out1 = full_run("best")
    m1 = re.search(r"^OVER score=(\d+) .*digest=(\w+)", out1, re.M)
    r.check("over", m1 is not None, "a still ship is eventually hit", out1)
    out2 = full_run("best")
    m2 = re.search(r"^OVER score=(\d+) .*digest=(\w+)", out2, re.M)
    if m1 and m2:
        r.check("over", m1.groups() == m2.groups(), "same seed + same input = same run", out2)
        r.check("over", f"BOOT best={m1.group(1)}" in out2, "best score persisted", out2)

    # 7. the IMU log round-trips into a simulator recording (scripts/log2trace.py)
    s = Session()
    s.imu(0.0, 1.2)
    s.imu(1.2, 3.0, roll=lambda t: 10 * math.sin(t * 3))
    s.tap(1.0, 160, 148)  # Settings
    s.tap(1.3, 100, 210)  # IMU log row -> on
    out = r.run("record", s, 3.0)
    log = r.tmp / "record.log"
    log.write_text(out)
    conv = subprocess.run([sys.executable, str(ROOT / "scripts/log2trace.py"), str(log)],
                          capture_output=True, text=True, check=False)
    lines = conv.stdout.splitlines()
    r.check("record", conv.returncode == 0 and len(lines) > 50, "IMU lines logged and converted", out)
    replayed = Session()
    replayed.sensors = [(int(t), int(k), float(x), float(y), float(z))
                        for t, k, x, y, z, _ in (ln.split() for ln in lines)]
    out = r.run("record_replay", replayed, 3.0)
    r.check("record_replay", "CALIBRATED" in out, "the converted trace drives the game", out)

    # 8. screens for docs: pause menu and settings
    if r.shots:
        s = Session()
        calibrated_start(s)
        s.imu(1.5, 7.0)
        s.tap(6.0, 300, 8)
        r.run("pause", s, 6.5)
        s = Session()
        s.imu(0.0, 3.0)
        s.tap(2.0, 160, 148)
        r.run("settings", s, 2.5)
        s = Session()
        s.imu(0.0, 6.5)
        s.imu(6.5, 8.0, roll=lambda t: -8, rate=lambda t: (0.0, -0.4, 0.0) if t < 6.85 else (0.0, 0.0, 0.0))
        s.tap(1.2, 160, 148)  # Settings
        s.tap(1.6, 100, 192)  # Diagnostics row -> on
        s.tap(2.0, 280, 10)  # Back
        s.tap(2.4, 160, 114)  # Start
        out = r.run("diag", s, 7.5)
        r.check("diag", "STATE play" in out, "diagnostics run reaches play", out)

    print("sim: " + ("OK" if r.failures == 0 else f"{r.failures} failure(s)"))
    return 0 if r.failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
