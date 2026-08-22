#!/usr/bin/env bash
# Pingify installer.
#
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/GreatTeejay/Pingify/main/install.sh)"
#
# Fetches the manager, installs it as /usr/local/bin/pingify, registers the
# systemd units and opens the menu. Run it on both servers.
set -euo pipefail

RAW="https://raw.githubusercontent.com/GreatTeejay/Pingify/main"
DEST="/usr/local/bin/pingify"

if [ "$(id -u)" != "0" ]; then
    echo "Pingify has to be installed as root:  sudo bash -c \"\$(curl -fsSL $RAW/install.sh)\"" >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "installing curl..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq curl ca-certificates >/dev/null 2>&1 || {
        echo "could not install curl; please install it and try again" >&2
        exit 1
    }
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "downloading Pingify..."
if ! curl -fsSL --retry 3 --max-time 120 "$RAW/Pingify.sh" -o "$tmp"; then
    echo "could not download Pingify from GitHub." >&2
    echo "If this server cannot reach GitHub, copy Pingify.sh across by hand:" >&2
    echo "  scp Pingify.sh root@this-server:/usr/local/bin/pingify" >&2
    echo "  ssh root@this-server 'chmod +x /usr/local/bin/pingify && pingify --install'" >&2
    exit 1
fi

if ! bash -n "$tmp" 2>/dev/null; then
    echo "the downloaded file is damaged; not installing it" >&2
    exit 1
fi

install -m 0755 "$tmp" "$DEST"
echo "installed $DEST ($("$DEST" --version))"

"$DEST" --install
exec "$DEST"
