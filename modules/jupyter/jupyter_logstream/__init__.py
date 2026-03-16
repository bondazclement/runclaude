"""jupyter_logstream — Jupyter Server extension for Claude Code.

Hooks into the IOPub channel to capture ALL notebook outputs
(human and API) and writes them to /workspace/claude/stream.jsonl.

Tags each output with source="human" or source="api" so Claude Code
doesn't process its own outputs in the monitoring stream.
"""

import json
import os
import threading
import time
from pathlib import Path

STREAM_FILE = os.environ.get("CLAUDE_STREAM_FILE", "/workspace/claude/stream.jsonl")
_stream_lock = threading.Lock()


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


def _detect_source(msg):
    """Detect if output came from human interaction or API."""
    # Messages from the REST API typically have metadata markers
    parent_header = msg.get("parent_header", {})
    # If executed via API, username is often empty or 'api'
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
        msg_type = msg.get("msg_type", "")
        content = msg.get("content", {})
        source = _detect_source(msg)

        base = {
            "source": f"jupyter.kernel",
            "kernel_id": self.kernel_id,
            "origin": source,
        }

        if msg_type == "stream":
            # stdout/stderr from cell execution
            base["type"] = "stream"
            base["stream_name"] = content.get("name", "stdout")
            text = content.get("text", "")
            # Truncate long outputs
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
            # Keep last 5 traceback lines, strip ANSI codes
            import re
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
            # Skip status and input echo messages — too noisy
            return

        else:
            # Log unknown message types at debug level
            base["type"] = msg_type
            base["level"] = "DEBUG"
            base["msg"] = json.dumps(content)[:300]

        _write_stream(base)


# ─── Jupyter Server Extension ─────────────────────────────────────────

_loggers = {}  # kernel_id -> IOPubLogger


def _patch_kernel_manager(kernel_manager):
    """Patch a kernel manager to intercept IOPub messages."""
    kernel_id = kernel_manager.kernel_id
    if kernel_id in _loggers:
        return

    logger = IOPubLogger(kernel_id)
    _loggers[kernel_id] = logger

    # Get the IOPub channel
    client = kernel_manager.client()
    iopub = client.iopub_channel

    # Store original handler
    original_call = iopub._call_handlers if hasattr(iopub, '_call_handlers') else None

    def patched_handler(msg):
        """Intercept IOPub messages."""
        try:
            logger.handle_message(msg)
        except Exception:
            pass  # Never crash the kernel for logging
        if original_call:
            original_call(msg)

    if hasattr(iopub, '_call_handlers'):
        iopub._call_handlers = patched_handler

    _write_stream({
        "source": "jupyter.logstream",
        "level": "INFO",
        "msg": f"Attached to kernel {kernel_id[:8]}",
    })


def _load_jupyter_server_extension(serverapp):
    """Entry point for Jupyter Server extension."""
    _write_stream({
        "source": "jupyter.logstream",
        "level": "INFO",
        "msg": "jupyter_logstream extension loaded",
    })

    # Hook into kernel lifecycle
    kernel_manager = serverapp.kernel_manager

    # Patch existing kernels
    if hasattr(kernel_manager, 'list_kernel_ids'):
        for kid in kernel_manager.list_kernel_ids():
            try:
                km = kernel_manager.get_kernel(kid)
                _patch_kernel_manager(km)
            except Exception:
                pass

    # Hook into new kernel starts
    original_start = kernel_manager.start_kernel

    async def patched_start(*args, **kwargs):
        result = await original_start(*args, **kwargs)
        try:
            km = kernel_manager.get_kernel(result)
            _patch_kernel_manager(km)
        except Exception:
            pass
        return result

    kernel_manager.start_kernel = patched_start
