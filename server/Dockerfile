FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Runs unprivileged. /data is the only thing it needs to write.
RUN useradd --system --uid 10001 horizon && mkdir -p /data /srv/web \
    && chown -R horizon:horizon /data /srv/web
USER horizon

EXPOSE 8080
# One worker: SQLite with WAL handles concurrent readers fine, but multiple
# worker processes writing the same file invites lock contention for no gain
# at this scale.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
