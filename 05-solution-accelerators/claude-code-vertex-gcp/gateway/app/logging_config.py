"""Structured JSON logging for Cloud Logging.

Cloud Logging auto-parses JSON on stdout from Cloud Run containers. Any
top-level field we emit becomes a structured, queryable field in Cloud
Logging. This lets the admin dashboard and Looker Studio filter by caller, model,
status, latency, etc. without any log-parsing regex.

Why not use ``google-cloud-logging``'s Python handler directly? Because on
Cloud Run the simplest and cheapest path is: write JSON to stdout, let the
platform pick it up. No extra network calls, no extra dependencies beyond
the stdlib ``logging`` module.

Usage::

    from .logging_config import configure_logging, get_logger

    configure_logging()
    log = get_logger(__name__)
    log.info("request", extra={"caller": "[email protected]", "model": "opus"})
"""

from __future__ import annotations

import json
import logging
import sys
from typing import Any


# Map Python log levels to Google Cloud Logging severities. Cloud Logging
# looks for a top-level "severity" field; if we emit the right value here,
# the log entry shows the correct severity color and icon in the UI.
_SEVERITY = {
    logging.DEBUG: "DEBUG",
    logging.INFO: "INFO",
    logging.WARNING: "WARNING",
    logging.ERROR: "ERROR",
    logging.CRITICAL: "CRITICAL",
}

# Attributes that stdlib ``logging.LogRecord`` sets for internal bookkeeping
# (filename, threadName, etc.). We skip these during serialization so our
# JSON payload stays focused on semantic fields.
_RESERVED_LOGRECORD_ATTRS = {
    "args", "asctime", "created", "exc_info", "exc_text", "filename",
    "funcName", "levelname", "levelno", "lineno", "message", "module",
    "msecs", "name", "pathname", "process", "processName",
    "relativeCreated", "stack_info", "thread", "threadName", "msg",
    "taskName",
}


class CloudLoggingJsonFormatter(logging.Formatter):
    """Serializes each log record as a single JSON object on one line.

    Anything passed in via ``extra={...}`` on a logger call becomes a
    top-level field, which means you can filter for it in Cloud Logging
    with queries like ``jsonPayload.caller="[email protected]"``.
    """

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "severity": _SEVERITY.get(record.levelno, "DEFAULT"),
            "message": record.getMessage(),
            "logger": record.name,
        }

        # Include exception text if there is one — Cloud Logging shows this
        # in the expanded entry view.
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)

        # Merge `extra={...}` fields. These arrive on the record as
        # attributes that are not part of the standard reserved set.
        for key, value in record.__dict__.items():
            if key in _RESERVED_LOGRECORD_ATTRS or key.startswith("_"):
                continue
            try:
                json.dumps(value)
                payload[key] = value
            except (TypeError, ValueError):
                # Non-JSON-serializable value — coerce to string so it still
                # lands in the log rather than being dropped silently.
                payload[key] = str(value)

        return json.dumps(payload, ensure_ascii=False)


def configure_logging(level: int = logging.INFO) -> None:
    """Configure the root logger for Cloud Logging-friendly JSON output.

    Call this exactly once at application startup, before any log calls.

    Args:
        level: Minimum log level to emit. Defaults to ``INFO``.
    """
    root = logging.getLogger()
    root.setLevel(level)

    # Replace any existing handlers (e.g., uvicorn's default plaintext
    # handler) with our JSON handler. Otherwise logs would emit twice in
    # two formats, which doubles cost and breaks structured parsing.
    for handler in list(root.handlers):
        root.removeHandler(handler)

    handler = logging.StreamHandler(stream=sys.stdout)
    handler.setFormatter(CloudLoggingJsonFormatter())
    root.addHandler(handler)

    # Route uvicorn's loggers through our root handler so access logs are
    # JSON-formatted too.
    for name in ("uvicorn", "uvicorn.access", "uvicorn.error"):
        lg = logging.getLogger(name)
        lg.handlers = []
        lg.propagate = True


def get_logger(name: str) -> logging.Logger:
    """Return a named logger. Thin wrapper over ``logging.getLogger``."""
    return logging.getLogger(name)
