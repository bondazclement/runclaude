"""handlers.py — IOPub capture strategies for jupyter_logstream.

Strategy 1 (jupyter_server >= 2.0): Use KernelWebsocketConnection event system.
Strategy 2 (fallback): Poll .ipynb files for new outputs every 30 seconds.

The strategy is selected automatically at load time.
Rule: NEVER crash Jupyter. All code in try/except.
"""

import json
import os
import re
import sys
import threading
import time
from pathlib import Path

STREAM_FILE = os.environ.get("CLAUDE_STREAM_FILE", "/workspace/claude/stream.jsonl")
_stream_lock = threading.Lock()
_polling_thread = None


def _write_stream(entry):
    """Thread-safe write to stream.jsonl."""
    entry["ts"] = entry.get("ts", int(time.time()))
    line = json.dumps(entry, ensure_ascii=False) + "\n"
    with _stream_lock:
        try:
            with open(STREAM_FILE, "a") as f:
                f.write(line)
        except OSError:
            pass


def _detect_origin(msg):
    """Detect if output came from human interaction or API."""
    parent_header = msg.get("parent_header", {})
    username = parent_header.get("username", "")
    if username in ("api", "claude", ""):
        return "api"
    return "human"


class IOPubLogger:
    """Captures IOPub messages and writes to stream.jsonl."""

    def __init__(self, kernel_id):
        self.kernel_id = kernel_id[:8] if kernel_id else "unknown"

    def handle_message(self, msg):
        """Process a single IOPub message."""
        try:
            msg_type = msg.get("msg_type", "")
            content = msg.get("content", {})
            origin = _detect_origin(msg)

            base = {
                "source": "jupyter.kernel",
                "kernel_id": self.kernel_id,
                "origin": origin,
            }

            if msg_type == "stream":
                base["type"] = "stream"
                base["stream_name"] = content.get("name", "stdout")
                text = content.get("text", "")
                if len(text) > 2000:
                    text = text[:2000] + f"... [truncated, {len(text)} chars total]"
                base["msg"] = text
                base["level"] = "ERROR" if content.get("name") == "stderr" else "INFO"

            elif msg_type == "execute_result":
                base["type"] = "result"
                data = content.get("data", {})
                text_repr = data.get("text/plain", "")
                if len(text_repr) > 1000:
                    text_repr = text_repr[:1000] + "... [truncated]"
                base["msg"] = text_repr
                base["level"] = "INFO"
                base["execution_count"] = content.get("execution_count")

            elif msg_type == "error":
                base["type"] = "error"
                base["level"] = "ERROR"
                base["ename"] = content.get("ename", "")
                base["evalue"] = content.get("evalue", "")[:500]
                traceback = content.get("traceback", [])
                ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
                clean_tb = [ansi_escape.sub('', line) for line in traceback[-5:]]
                base["traceback_tail"] = clean_tb
                base["msg"] = f"{base['ename']}: {base['evalue']}"

            elif msg_type == "display_data":
                base["type"] = "display"
                base["level"] = "INFO"
                data = content.get("data", {})
                if "text/plain" in data:
                    base["msg"] = data["text/plain"][:500]
                elif "text/html" in data:
                    base["msg"] = "[HTML output]"
                elif "image/png" in data:
                    base["msg"] = "[PNG image]"
                else:
                    base["msg"] = f"[display: {', '.join(data.keys())}]"

            elif msg_type in ("status", "execute_input"):
                return  # Skip noisy messages

            else:
                base["type"] = msg_type
                base["level"] = "DEBUG"
                base["msg"] = json.dumps(content)[:300]

            _write_stream(base)
        except Exception:
            pass  # Never crash


# ─── Strategy 1: Event hook (jupyter_server >= 2.0) ──────────────────

def _try_event_hook(serverapp):
    """Try to use KernelWebsocketConnection for message interception."""
    try:
        from jupyter_server.services.kernels.websocket import KernelWebsocketConnection

        _loggers = {}
        original_write = KernelWebsocketConnection.write_message

        def patched_write(self, message, binary=False):
            try:
                if not binary and isinstance(message, str):
                    msg = json.loads(message)
                    kernel_id = getattr(self, 'kernel_id', 'unknown')
                    if kernel_id not in _loggers:
                        _loggers[kernel_id] = IOPubLogger(kernel_id)
                    _loggers[kernel_id].handle_message(msg)
            except (json.JSONDecodeError, Exception):
                pass
            return original_write(self, message, binary)

        KernelWebsocketConnection.write_message = patched_write

        _write_stream({
            "source": "jupyter.logstream",
            "level": "INFO",
            "msg": "using strategy=event_hook",
        })
        return True
    except (ImportError, AttributeError, Exception):
        return False


# ─── Strategy 2: Notebook polling (fallback) ─────────────────────────

class NotebookPoller:
    """Poll .ipynb files for new outputs."""

    def __init__(self, workspace="/workspace"):
        self.workspace = Path(workspace)
        self.notebook_states = {}  # {path: {cell_idx: execution_count}}
        self.interval = 30

    def poll_once(self):
        """Check all notebooks for new outputs."""
        try:
            for nb_path in self.workspace.rglob("*.ipynb"):
                # Skip hidden dirs and checkpoints
                if ".ipynb_checkpoints" in str(nb_path):
                    continue
                try:
                    self._check_notebook(nb_path)
                except Exception:
                    continue
        except Exception:
            pass

    def _check_notebook(self, nb_path):
        """Check a single notebook for new cell outputs."""
        try:
            with open(nb_path, "r", errors="replace") as f:
                nb = json.load(f)
        except (json.JSONDecodeError, OSError):
            return

        cells = nb.get("cells", [])
        str_path = str(nb_path)
        prev_state = self.notebook_states.get(str_path, {})
        new_state = {}

        for idx, cell in enumerate(cells):
            if cell.get("cell_type") != "code":
                continue

            exec_count = cell.get("execution_count")
            if exec_count is None:
                continue

            new_state[idx] = exec_count
            prev_exec = prev_state.get(idx)

            # New or updated execution
            if prev_exec is None or prev_exec != exec_count:
                outputs = cell.get("outputs", [])
                for output in outputs:
                    self._log_output(nb_path.name, idx, exec_count, output)

        self.notebook_states[str_path] = new_state

    def _log_output(self, nb_name, cell_idx, exec_count, output):
        """Log a cell output to stream.jsonl."""
        try:
            output_type = output.get("output_type", "unknown")
            entry = {
                "source": "jupyter.notebook_poll",
                "notebook": nb_name,
                "cell_idx": cell_idx,
                "execution_count": exec_count,
                "origin": "human",  # Polling can't distinguish, default human
                "level": "INFO",
            }

            if output_type == "stream":
                text = "".join(output.get("text", []))
                if len(text) > 2000:
                    text = text[:2000] + "... [truncated]"
                entry["msg"] = text
                if output.get("name") == "stderr":
                    entry["level"] = "ERROR"

            elif output_type == "execute_result":
                data = output.get("data", {})
                text = data.get("text/plain", "")
                if len(text) > 1000:
                    text = text[:1000] + "... [truncated]"
                entry["msg"] = text

            elif output_type == "error":
                entry["level"] = "ERROR"
                ename = output.get("ename", "")
                evalue = output.get("evalue", "")[:500]
                entry["msg"] = f"{ename}: {evalue}"

            elif output_type == "display_data":
                data = output.get("data", {})
                if "text/plain" in data:
                    entry["msg"] = data["text/plain"][:500]
                else:
                    entry["msg"] = f"[display: {', '.join(data.keys())}]"

            else:
                entry["msg"] = f"[{output_type}]"

            _write_stream(entry)
        except Exception:
            pass

    def run_forever(self):
        """Run polling loop in background thread."""
        while True:
            try:
                self.poll_once()
            except Exception:
                pass
            time.sleep(self.interval)


def _start_notebook_polling():
    """Start the notebook polling fallback strategy."""
    global _polling_thread

    poller = NotebookPoller()
    _polling_thread = threading.Thread(target=poller.run_forever, daemon=True)
    _polling_thread.start()

    _write_stream({
        "source": "jupyter.logstream",
        "level": "INFO",
        "msg": "using strategy=notebook_polling, interval=30s",
    })


# ─── Main entry point ────────────────────────────────────────────────

def attach_iopub_logger(serverapp):
    """Attach IOPub logger using the best available strategy."""
    _write_stream({
        "source": "jupyter.logstream",
        "level": "INFO",
        "msg": "jupyter_logstream extension loaded",
    })

    # Try Strategy 1 first (event hook)
    if _try_event_hook(serverapp):
        return

    # Fallback to Strategy 2 (notebook polling)
    _start_notebook_polling()
