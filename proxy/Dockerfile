FROM python:3.14-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Patch OS packages the base image ships with known fixes available - the
# CI image scan (Trivy, HIGH/CRITICAL, fail-on-fixable) gates on these.
# Rebuilding picks up whatever is current, so this does not need pinning.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Remove pip from the runtime image. pip vendors its own copies of setuptools
# and msgpack (pip/_vendor/vendor.txt) which the image scanner flags even
# though nothing at runtime imports them; a runtime container also has no
# business installing packages.
#
# Deleted explicitly rather than via `pip uninstall`: uninstalling pip with
# pip is self-referential and its exit status is unreliable, and an earlier
# version of this file paired it with `|| true`, which let a build that
# installed nothing still succeed. An explicit rm has no such ambiguity.
RUN rm -rf /usr/local/lib/python3.14/site-packages/pip \
           /usr/local/lib/python3.14/site-packages/pip-*.dist-info \
           /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.14

# Fail the BUILD if the dependency layer did not actually produce a working
# environment. A poisoned BuildKit cache once served the install step as a
# no-op, yielding an image with only pip in site-packages; it pushed and
# deployed cleanly and only surfaced as tasks that would not start. Assert
# here so that failure mode is impossible to ship.
RUN python -c "import fastapi, uvicorn, httpx, pydantic, pydantic_settings; print('dependency check OK')"

COPY app ./app

RUN useradd --create-home --shell /usr/sbin/nologin appuser
USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
