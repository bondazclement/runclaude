from setuptools import setup, find_packages

setup(
    name="jupyter-logstream",
    version="0.1.0",
    description="Jupyter Server extension for Claude Code — captures all notebook outputs to stream.jsonl",
    packages=find_packages(),
    python_requires=">=3.8",
    install_requires=[
        "jupyter_server>=1.0",
    ],
    entry_points={
        "jupyter_server.extensions": [
            "jupyter_logstream = jupyter_logstream:_load_jupyter_server_extension",
        ],
    },
)
