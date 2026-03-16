"""Handlers for jupyter_logstream."""

import glob
import json
import os
import time
from pathlib import Path

from jupyter_server.base.handlers import APIHandler
from jupyter_server.utils import url_path_join
from tornado import web


def _safe_log(stream_file, payload):
    payload.setdefault("ts", int(time.time()))
    try:
        Path(stream_file).parent.mkdir(parents=True, exist_ok=True)
        with open(stream_file, "a", encoding="utf-8") as f:
            f.write(json.dumps(payload, ensure_ascii=False) + "\n")
    except Exception:
        pass


class LogStreamHandler(APIHandler):
    @web.authenticated
    async def post(self):
        stream_file = self.settings.get("jupyter_logstream_file", "/workspace/claude/stream.jsonl")
        try:
            body = self.get_json_body() or {}
            _safe_log(stream_file, {
                "source": "jupyter.output",
                "level": "INFO",
                "origin": body.get("origin", "api"),
                "kernel_id": body.get("kernel_id"),
                "msg_type": body.get("msg_type"),
                "content": body.get("content"),
            })
            self.finish({"ok": True})
        except Exception as exc:
            _safe_log(stream_file, {"source": "jupyter.output", "level": "WARNING", "msg": f"capture failed: {exc}"})
            self.finish({"ok": False})


def register_logstream_routes(app):
    web_app = app.serverapp.web_app
    base_url = web_app.settings.get("base_url", "/")
    route_pattern = url_path_join(base_url, "/jupyter-logstream/capture")
    handlers = [(route_pattern, LogStreamHandler)]
    web_app.add_handlers(".*$", handlers)


def start_notebook_polling(stream_file):
    _safe_log(stream_file, {"source": "jupyter.extension", "level": "WARNING", "msg": "jupyter_logstream: using fallback notebook polling"})
    seen = {}
    while True:
        for path in glob.glob("/workspace/**/*.ipynb", recursive=True):
            try:
                mtime = os.path.getmtime(path)
                if seen.get(path) == mtime:
                    continue
                seen[path] = mtime
                with open(path, "r", encoding="utf-8") as f:
                    nb = json.load(f)
                for i, cell in enumerate(nb.get("cells", [])):
                    for output in cell.get("outputs", []):
                        _safe_log(stream_file, {
                            "source": "jupyter.output",
                            "level": "INFO",
                            "origin": "human",
                            "notebook": path,
                            "cell_index": i,
                            "content": output,
                        })
            except Exception:
                continue
        time.sleep(30)
