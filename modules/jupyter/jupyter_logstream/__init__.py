"""jupyter_logstream — Jupyter Server extension for Claude Code.

Captures all notebook outputs and writes them to /workspace/claude/stream.jsonl.
Uses ExtensionApp (stable public API) for integration with jupyter_server >= 1.6.
"""

from jupyter_server.extension.application import ExtensionApp
from .handlers import attach_iopub_logger


class JupyterLogstreamApp(ExtensionApp):
    name = "jupyter_logstream"

    def initialize_settings(self):
        try:
            attach_iopub_logger(self.serverapp)
        except Exception as e:
            # NEVER crash Jupyter
            import sys
            print(f"jupyter_logstream: init failed silently: {e}", file=sys.stderr)
