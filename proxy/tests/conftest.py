"""Baseline environment for the test suite.

app.config builds its Settings at import time, so these must be in place
before any test module imports the application.
"""

import json
import os

os.environ.setdefault("ELASTIC_API_KEY", "test-key")
os.environ.setdefault("EIS_ENDPOINT_URL", "https://example-project.es.example.com")
os.environ.setdefault("PROXY_API_KEY", "test-proxy-token")
os.environ.setdefault(
    "EIS_MODEL_MAP",
    json.dumps({"claude": "proj-chat-claude", "gemini": "proj-chat-gemini"}),
)
