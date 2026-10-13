#!/usr/bin/env python3
"""Turn the game's IMU log (setting "IMU log", read with `giii logs`) into a simulator
sensor recording, so a device session can be replayed on the PC:

    giii logs --port /dev/ttyACM0 > session.log
    python3 scripts/log2trace.py session.log > session.sensors
    giii sim app --sensors session.sensors --frames 1800

Only the newest sample per frame reaches the game (docs/api-gaps.md), so the trace has
the game's view of the sensor, not every sample the IMU produced.
"""
import re
import sys

LINE = re.compile(r"IMU (\d+) ([12]) (\S+) (\S+) (\S+) (\S+)")


def main() -> int:
    last = -1
    for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
        m = LINE.search(line)
        if not m:
            continue
        t = int(m.group(1))
        if t < last:  # the simulator needs non-decreasing time; a restart begins a new trace
            print(f"log2trace: time went back at {t}, stopping", file=sys.stderr)
            break
        last = t
        print(" ".join(m.groups()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
