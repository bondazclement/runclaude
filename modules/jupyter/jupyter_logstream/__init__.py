"""Jupyter extension app for log streaming."""

import json
import os
import threading
import time
from pathlib import Path

from jupyter_server.extension.application import ExtensionApp

from .handlers import register_logstream_routes


class JupyterLogstreamApp(ExtensionApp):
    name = "jupyter_logstream"

    def initialize_settings(self):
        self.stream_file = Path(os.environ.get("JUPYTER_LOGSTREAM_FILE", "/workspace/claude/stream.jsonl"))
        self.stream_file.parent.mkdir(parents=True, exist_ok=True)
        self.stream_file.touch(exist_ok=True)
        self.serverapp.settings["jupyter_logstream_file"] = str(self.stream_file)

    def initialize_handlers(self):
        register_logstream_routes(self)
        self.log.info("jupyter_logstream: websocket handler registered")

    def _safe_write(self, payload):
        payload.setdefault("ts", int(time.time()))
        try:
            with self.stream_file.open("a", encoding="utf-8") as f:
                f.write(json.dumps(payload, ensure_ascii=False) + "\n")
        except Exception:
            pass

    def start(self):
        try:
            super().start()
        except Exception as exc:
            self._safe_write({"source": "jupyter.extension", "level": "WARNING", "msg": f"start error: {exc}"})


def _jupyter_server_extension_points():
    return [{"module": "jupyter_logstream", "app": JupyterLogstreamApp}]


def _load_jupyter_server_extension(serverapp):
    app = JupyterLogstreamApp()
    app.serverapp = serverapp
    try:
        app.initialize_settings()
        app.initialize_handlers()
    except Exception as exc:
        stream = Path(os.environ.get("JUPYTER_LOGSTREAM_FILE", "/workspace/claude/stream.jsonl"))
        stream.parent.mkdir(parents=True, exist_ok=True)
        with stream.open("a", encoding="utf-8") as f:
            f.write(json.dumps({
                "ts": int(time.time()),
                "source": "jupyter.extension",
                "level": "WARNING",
                "msg": f"jupyter_logstream: using fallback notebook polling ({exc})",
            }) + "\n")
        # Fallback notebook polling.
        from .handlers import start_notebook_polling

        t = threading.Thread(target=start_notebook_polling, args=(str(stream),), daemon=True)
        t.start()
