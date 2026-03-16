#!/usr/bin/env python3
"""logd.py — collecteur RunPod robuste (JSONL)."""

import glob
import json
import os
import signal
import subprocess
import threading
import time
from pathlib import Path

WORKSPACE_DIR = os.environ.get("WORKSPACE_DIR", "/workspace")
CLAUDE_DIR = os.path.join(WORKSPACE_DIR, "claude")
LOGS_DIR = os.path.join(WORKSPACE_DIR, "logs")
STREAM_FILE = os.path.join(CLAUDE_DIR, "stream.jsonl")
MAX_STREAM_SIZE_MB = 50
METRICS_INTERVAL = 5
LOG_WATCH_INTERVAL = 1

SYSTEM_NAME_PREFIXES = [
    "kthreadd", "ksoftirqd", "kworker", "rcu_", "migration", "idle",
    "cpuhp", "watchdog", "irq/", "smpboot", "oom_reaper",
]

running = True


def _signal_handler(_sig, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, _signal_handler)
signal.signal(signal.SIGINT, _signal_handler)


class StreamWriter:
    def __init__(self, path: str, max_mb: int):
        self.path = Path(path)
        self.max_bytes = max_mb * 1024 * 1024
        self.lock = threading.Lock()
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.touch(exist_ok=True)
        except OSError:
            fallback_dir = Path("/tmp/claude")
            fallback_dir.mkdir(parents=True, exist_ok=True)
            self.path = fallback_dir / "stream.jsonl"
            self.path.touch(exist_ok=True)

    def write(self, entry: dict):
        payload = dict(entry)
        payload.setdefault("ts", int(time.time()))
        line = json.dumps(payload, ensure_ascii=False) + "\n"
        with self.lock:
            try:
                with self.path.open("a", encoding="utf-8") as f:
                    f.write(line)
                if self.path.stat().st_size > self.max_bytes:
                    self._rotate()
            except Exception:
                pass

    def _rotate(self):
        try:
            lines = self.path.read_text(encoding="utf-8", errors="ignore").splitlines()
            keep_from = len(lines) * 4 // 10
            self.path.write_text("\n".join(lines[keep_from:]) + "\n", encoding="utf-8")
        except Exception:
            pass


def run_cmd(cmd, timeout=5):
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return proc.stdout.strip(), proc.stderr.strip(), proc.returncode
    except Exception:
        return "", "", -1


def detect_jupyter(writer):
    """Detect if Jupyter Server is running and log its state."""
    stdout, stderr, rc = run_cmd(["jupyter", "server", "list", "--json"], timeout=5)
    if rc == 0 and stdout:
        try:
            for line in stdout.splitlines():
                item = json.loads(line)
                writer.write({
                    "source": "jupyter.server",
                    "level": "INFO",
                    "msg": "Jupyter server detected",
                    "url": item.get("url"),
                    "token": bool(item.get("token")),
                })
        except Exception as exc:
            writer.write({"source": "jupyter.server", "level": "WARNING", "msg": f"parse error: {exc}"})
    else:
        writer.write({"source": "jupyter.server", "level": "INFO", "msg": "Jupyter server not detected", "stderr": stderr[:200]})


def collect_gpu(writer):
    out, _, rc = run_cmd([
        "nvidia-smi",
        "--query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu",
        "--format=csv,noheader,nounits",
    ], timeout=5)
    if rc != 0:
        return
    for line in out.splitlines():
        try:
            i, util, mu, mt, temp = [x.strip() for x in line.split(",")]
            writer.write({"source": "system.gpu", "gpu_index": int(i), "util_pct": int(util), "mem_used_mb": int(mu), "mem_total_mb": int(mt), "temp_c": int(temp)})
        except Exception:
            continue


def collect_system(writer):
    try:
        import psutil
        mem = psutil.virtual_memory()
        disk = psutil.disk_usage(WORKSPACE_DIR if os.path.isdir(WORKSPACE_DIR) else "/")
        writer.write({"source": "system.mem", "used_mb": int(mem.used / 1024 / 1024), "total_mb": int(mem.total / 1024 / 1024), "pct": round(mem.percent, 1)})
        writer.write({"source": "system.disk", "path": WORKSPACE_DIR, "used_gb": round(disk.used / 1024 ** 3, 2), "free_gb": round(disk.free / 1024 ** 3, 2), "pct": round(disk.percent, 1)})
    except Exception as exc:
        writer.write({"source": "system", "level": "WARNING", "msg": f"psutil unavailable: {exc}"})


def _proc_state(pid):
    try:
        with open(f"/proc/{pid}/status", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("State:"):
                    return line.split(":", 1)[1].strip()
    except Exception:
        return "unknown"
    return "unknown"


def _is_system_process(name: str):
    lname = (name or "").lower()
    return any(lname.startswith(prefix.lower()) for prefix in SYSTEM_NAME_PREFIXES)


def collect_processes(writer):
    try:
        import psutil
        for p in psutil.process_iter(["pid", "name", "cpu_percent", "memory_info"]):
            try:
                info = p.info
                pid = int(info.get("pid", 0))
                name = info.get("name") or "unknown"
                cpu = float(info.get("cpu_percent") or 0.0)
                mem_mb = float((info.get("memory_info").rss if info.get("memory_info") else 0) / 1024 / 1024)
                state = _proc_state(pid)

                if _is_system_process(name) and cpu < 0.5 and mem_mb < 20:
                    continue

                entry = {
                    "source": "system.proc",
                    "pid": pid,
                    "name": name,
                    "cpu_pct": round(cpu, 2),
                    "mem_mb": round(mem_mb, 2),
                    "state": state,
                }
                if "zombie" in state.lower():
                    entry["level"] = "WARNING"
                writer.write(entry)
            except Exception:
                continue
    except Exception as exc:
        writer.write({"source": "system.proc", "level": "WARNING", "msg": f"collect failed: {exc}"})


def collect_dmesg(writer):
    out, _, rc = run_cmd(["dmesg", "--ctime", "--level=err,warn"], timeout=5)
    if rc != 0:
        return
    for line in out.splitlines()[-20:]:
        low = line.lower()
        if "oom" in low or "killed process" in low or "nvrm" in low:
            writer.write({"source": "system.kernel", "level": "WARNING", "msg": line})


def watch_logs(writer):
    offsets = {}
    while running:
        try:
            for log_path in glob.glob(os.path.join(LOGS_DIR, "*.log")):
                if log_path not in offsets:
                    offsets[log_path] = 0
                try:
                    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
                        f.seek(offsets[log_path])
                        for line in f:
                            writer.write({"source": Path(log_path).stem, "level": "INFO", "msg": line.rstrip("\n")})
                        offsets[log_path] = f.tell()
                except Exception:
                    continue
        except Exception:
            pass
        time.sleep(LOG_WATCH_INTERVAL)


def metrics_loop(writer):
    while running:
        collect_gpu(writer)
        collect_system(writer)
        collect_processes(writer)
        collect_dmesg(writer)
        time.sleep(METRICS_INTERVAL)


def main():
    writer = StreamWriter(STREAM_FILE, MAX_STREAM_SIZE_MB)
    writer.write({"source": "logd", "level": "INFO", "msg": "logd started"})
    detect_jupyter(writer)

    t_logs = threading.Thread(target=watch_logs, args=(writer,), daemon=True)
    t_metrics = threading.Thread(target=metrics_loop, args=(writer,), daemon=True)
    t_logs.start()
    t_metrics.start()

    while running:
        time.sleep(1)

    writer.write({"source": "logd", "level": "INFO", "msg": "logd stopped"})


if __name__ == "__main__":
    main()
