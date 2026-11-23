#!/bin/sh
# Runs as root only long enough to make the mounted folders writable, then drops to PUID:PGID.
# (Docker creates missing bind-mount folders as root, which the app user can't write to.)
set -e
PUID=${PUID:-1000}
PGID=${PGID:-1000}

if [ "$(id -u)" = 0 ]; then
  for d in "$DATA_DIR" "$DOWNLOADS_DIR"; do
    mkdir -p "$d"
    owner=$(stat -c %u "$d")
    if [ "$owner" = 0 ]; then
      chown "$PUID:$PGID" "$d"   # only the folder itself; files inside are left alone
      echo "hlsgrab: $d was owned by root, handed it to $PUID:$PGID"
    elif [ "$owner" != "$PUID" ]; then
      echo "hlsgrab: warning: $d is owned by uid $owner but the app runs as $PUID (set PUID/PGID to match)"
    fi
  done
  exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups /app/start.sh
fi

exec /app/start.sh   # already started as a non-root user (e.g. compose `user:`)
