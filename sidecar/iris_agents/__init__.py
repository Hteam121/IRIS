"""IRIS background-agent sidecar.

A small FastAPI server that runs LangGraph agents concurrently and streams their
state back to the IRIS macOS app over localhost (HTTP + SSE). See server.py.
"""

__version__ = "0.1.0"
