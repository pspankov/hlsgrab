#!/bin/sh
# Start a virtual X display for headful Chrome, then the web server (runs as the app user).
set -e
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
Xvfb "${DISPLAY:-:99}" -screen 0 1280x800x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
i=0
while [ ! -e "/tmp/.X11-unix/X${DISPLAY#:}" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -e "/tmp/.X11-unix/X${DISPLAY#:}" ] || { echo "Xvfb did not start:"; cat /tmp/xvfb.log; exit 1; }
exec node /app/server.mjs
