"""
Launches both overlay panel windows (each its own process, since pygame
only supports one window per process) against a running RAVBA instance.

Usage: python ravba_overlay_launcher.py [--scale N]
"""

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent


def main():
    extra_args = sys.argv[1:]
    procs = [
        subprocess.Popen([sys.executable, str(HERE / "ravba_overlay_right.py"), *extra_args]),
        subprocess.Popen([sys.executable, str(HERE / "ravba_overlay_bottom.py"), *extra_args]),
    ]
    try:
        for p in procs:
            p.wait()
    except KeyboardInterrupt:
        for p in procs:
            p.terminate()


if __name__ == "__main__":
    main()
