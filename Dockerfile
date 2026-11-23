# hlsgrab: web UI around batch_m3u8.sh — Chrome (headful on a virtual X display), ffmpeg, yt-dlp.
FROM node:24-trixie-slim

ARG YTDLP_VERSION=2026.08.19

# ffmpeg 7.1 (trixie) supports -extension_picky / -allowed_segment_extensions used for disguised HLS.
# xvfb gives Chrome a virtual screen, so it can run headful (sites detect headless Chrome).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl jq python3 ffmpeg xvfb xauth \
      fonts-liberation fonts-noto-core fonts-noto-color-emoji \
 && curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb \
 && apt-get install -y --no-install-recommends /tmp/chrome.deb \
 && rm -f /tmp/chrome.deb \
 && curl -fsSL "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp" -o /usr/local/bin/yt-dlp \
 && chmod 755 /usr/local/bin/yt-dlp \
 && rm -rf /var/lib/apt/lists/*

# Chrome inside a container: no user-namespace sandbox, small /dev/shm.
RUN printf '#!/bin/sh\nexec google-chrome-stable --no-sandbox --disable-dev-shm-usage "$@"\n' > /usr/local/bin/chrome \
 && chmod 755 /usr/local/bin/chrome

WORKDIR /app
COPY batch_m3u8.sh server.mjs entrypoint.sh start.sh ./
COPY public ./public
RUN chmod 755 batch_m3u8.sh entrypoint.sh start.sh \
 && ln -s /app/batch_m3u8.sh /usr/local/bin/batch_m3u8 \
 && mkdir -p /data /downloads && chown node:node /data /downloads

ENV CHROME=/usr/local/bin/chrome \
    DATA_DIR=/data \
    DOWNLOADS_DIR=/downloads \
    PORT=8090 \
    DISPLAY=:99 \
    XDG_CACHE_HOME=/tmp/.cache \
    HOME=/tmp \
    PUID=1000 \
    PGID=1000

# Starts as root only to fix ownership of the mounted folders, then drops to PUID:PGID (see entrypoint.sh).
EXPOSE 8090
VOLUME ["/data", "/downloads"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/api/state" -u "${AUTH:-x:x}" || exit 1
ENTRYPOINT ["/app/entrypoint.sh"]
