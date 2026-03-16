#!/usr/bin/env python3
"""logd.py — Daemon collecteur agnostique pour pods RunPod.

Collecte métriques système, GPU, processus et logs applicatifs.
Écrit tout dans /workspace/claude/stream.jsonl (ring buffer 50MB).
"""

import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

# ─── Configuration ────────────────────────────────────────────────────

STREAM_FILE = "/workspace/claude/stream.jsonl"
LOGS_DIR = "/workspace/logs"
MAX_STREAM_SIZE_MB = 50
METRICS_INTERVAL = 5  # seconds
LOG_WATCH_INTERVAL = 1  # seconds
ARCHIVE_AGE_HOURS = 6

# ─── Globals ──────────────────────────────────────────────────────────

running = True


def signal_handler(_sig, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)


# ─── Stream Writer ────────────────────────────────────────────────────

class StreamWriter:
    """Thread-safe JSONL writer with ring buffer."""

    def __init__(self, filepath, max_size_mb):
        self.filepath = Path(filepath)
        self.max_size_bytes = max_size_mb * 1024 * 1024
        self.lock = threading.Lock()
        self.filepath.parent.mkdir(parents=True, exist_ok=True)
        self.filepath.touch(exist_ok=True)

    def write(self, entry):
        """Write a JSONL entry, rotating if needed."""
        entry["ts"] = entry.get("ts", int(time.time()))
        line = json.dumps(entry, ensure_ascii=False) + "\n"

        with self.lock:
            try:
                with open(self.filepath, "a") as f:
                    f.write(line)
            except OSError as e:
                print(f"logd: write error: {e}", file=sys.stderr)
                return

            # Check size and rotate if needed
            try:
                if self.filepath.stat().st_size > self.max_size_bytes:
                    self._rotate()
            except OSError:
                pass

    def _rotate(self):
        """Keep last 60% of lines on rotation."""
        try:
            with open(self.filepath, "r") as f:
                lines = f.readlines()

            # Keep last 60%
            keep_from = len(lines) * 4 // 10
            with open(self.filepath, "w") as f:
                f.writelines(lines[keep_from:])

            print(f"logd: rotated stream.jsonl, kept {len(lines) - keep_from}/{len(lines)} lines",
                  file=sys.stderr)
        except OSError as e:
            print(f"logd: rotation error: {e}", file=sys.stderr)


# ─── Collectors ───────────────────────────────────────────────────────

def collect_gpu(writer):
    """Collect GPU metrics via nvidia-smi."""
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return

        for line in result.stdout.strip().split("\n"):
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 5:
                writer.write({
                    "source": "system.gpu",
                    "gpu_index": int(parts[0]),
                    "util_pct": int(parts[1]),
                    "mem_used_mb": int(parts[2]),
                    "mem_total_mb": int(parts[3]),
                    "temp_c": int(parts[4]),
                })
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass


def collect_system(writer):
    """Collect CPU, RAM, disk metrics."""
    try:
        import psutil

        mem = psutil.virtual_memory()
        writer.write({
            "source": "system.mem",
            "used_mb": round(mem.used / (1024**2)),
            "total_mb": round(mem.total / (1024**2)),
            "pct": mem.percent,
        })

        writer.write({
            "source": "system.cpu",
            "pct": psutil.cpu_percent(interval=0),
            "load_1m": round(os.getloadavg()[0], 2),
        })

        try:
            disk = psutil.disk_usage("/workspace")
            writer.write({
                "source": "system.disk",
                "free_gb": round(disk.free / (1024**3), 1),
                "used_pct": disk.percent,
            })
        except FileNotFoundError:
            pass

    except ImportError:
        pass


def collect_processes(writer):
    """Collect active process info."""
    try:
        import psutil

        for proc in psutil.process_iter(["pid", "name", "cpu_percent", "memory_info"]):
            try:
                info = proc.info
                cpu = info.get("cpu_percent") or 0
                if cpu < 1 and info["pid"] > 100:
                    continue  # Skip idle processes
                ram_mb = round(info["memory_info"].rss / (1024**2)) if info.get("memory_info") else 0
                if ram_mb < 50 and cpu < 1:
                    continue  # Skip insignificant processes

                writer.write({
                    "source": "system.proc",
                    "pid": info["pid"],
                    "name": info["name"],
                    "cpu_pct": round(cpu, 1),
                    "ram_mb": ram_mb,
                })
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
    except ImportError:
        pass


def collect_dmesg(writer, last_dmesg_ts):
    """Collect critical kernel messages."""
    try:
        result = subprocess.run(
            ["dmesg", "--level=emerg,alert,crit,err", "-T", "--since", f"@{last_dmesg_ts}"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            for line in result.stdout.strip().split("\n")[-10:]:  # Last 10 messages
                writer.write({
                    "source": "system.kernel",
                    "level": "ERROR",
                    "msg": line.strip()[:500],
                })
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass


# ─── Log File Watcher ────────────────────────────────────────────────

class LogWatcher:
    """Watch /workspace/logs/*.log files for new content."""

    def __init__(self, writer, logs_dir):
        self.writer = writer
        self.logs_dir = Path(logs_dir)
        self.file_positions = {}  # {filepath: last_position}

    def check(self):
        """Check for new content in log files."""
        if not self.logs_dir.exists():
            return

        for logfile in self.logs_dir.glob("*.log"):
            try:
                self._read_new_lines(logfile)
            except (OSError, PermissionError):
                continue

    def _read_new_lines(self, filepath):
        """Read new lines from a log file since last position."""
        str_path = str(filepath)
        current_size = filepath.stat().st_size

        last_pos = self.file_positions.get(str_path, 0)

        # File was truncated or rotated
        if current_size < last_pos:
            last_pos = 0

        if current_size == last_pos:
            return  # No new content

        with open(filepath, "r", errors="replace") as f:
            f.seek(last_pos)
            new_lines = f.readlines()
            self.file_positions[str_path] = f.tell()

        log_name = filepath.stem  # e.g., "training" from "training.log"

        for line in new_lines[-50:]:  # Cap at 50 new lines per check
            line = line.strip()
            if not line:
                continue

            level = "INFO"
            line_lower = line.lower()
            if "error" in line_lower or "exception" in line_lower or "traceback" in line_lower:
                level = "ERROR"
            elif "warn" in line_lower:
                level = "WARNING"

            self.writer.write({
                "source": log_name,
                "level": level,
                "msg": line[:1000],  # Cap line length
            })


# ─── Main Loop ────────────────────────────────────────────────────────

def main():
    print("logd: starting...", file=sys.stderr)

    writer = StreamWriter(STREAM_FILE, MAX_STREAM_SIZE_MB)
    log_watcher = LogWatcher(writer, LOGS_DIR)

    # Check if nvidia-smi is available
    has_nvidia = subprocess.run(
        ["which", "nvidia-smi"], capture_output=True
    ).returncode == 0

    # Initialize psutil CPU measurement
    try:
        import psutil
        psutil.cpu_percent(interval=0)
    except ImportError:
        print("logd: psutil not available, system metrics limited", file=sys.stderr)

    last_metrics_time = 0
    last_dmesg_ts = int(time.time())

    writer.write({
        "source": "logd",
        "level": "INFO",
        "msg": f"logd started, nvidia={'yes' if has_nvidia else 'no'}",
    })

    print("logd: running", file=sys.stderr)

    while running:
        now = time.time()

        # Collect metrics every METRICS_INTERVAL seconds
        if now - last_metrics_time >= METRICS_INTERVAL:
            if has_nvidia:
                collect_gpu(writer)
            collect_system(writer)
            collect_processes(writer)
            collect_dmesg(writer, last_dmesg_ts)
            last_dmesg_ts = int(now)
            last_metrics_time = now

        # Check log files every LOG_WATCH_INTERVAL seconds
        log_watcher.check()

        time.sleep(LOG_WATCH_INTERVAL)

    writer.write({
        "source": "logd",
        "level": "INFO",
        "msg": "logd stopped",
    })
    print("logd: stopped", file=sys.stderr)


if __name__ == "__main__":
    main()
