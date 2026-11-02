#!/usr/bin/env bash
# Puts Free My TV on the Raspberry Pi and (re)starts it.
#   ./deploy.sh pi@192.168.1.35
#   ./deploy.sh pi@192.168.1.35 ~/.ssh/id_ed25519_pi      # with a specific SSH key
# Copies this folder to ~/tv-remote on the Pi, the TV's pairing (tv.json) the first time, then builds and starts
# both containers. The first build takes a while on a Pi (the web app compiles there): 5 to 15 minutes.
set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:?Usage: ./deploy.sh user@192.168.1.35 [ssh key file]}"
KEY="${2:-}"
SSH_OPTS=(-o ConnectTimeout=10)   # never empty: macOS bash 3.2 with set -u rejects an empty array
if [ -n "$KEY" ]; then
  SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
fi

# The newest fork package (nuvio-web-v<N>.tar), unpacked fresh each time.
TAR="$(ls nuvio-web-v*.tar | sort -V | tail -1)"
echo "Unpacking $TAR ..."
rm -rf nuvio-web
tar xf "$TAR"

echo "Copying to $TARGET:~/tv-remote ..."
ssh "${SSH_OPTS[@]}" "$TARGET" 'mkdir -p ~/tv-remote/data/tv'
rsync -az --delete -e "ssh ${SSH_OPTS[*]}" \
  --exclude '.venv' --exclude '/*.ipk' --exclude '/*.tar' --exclude '/data/' --exclude '/tv.json' \
  --exclude '__pycache__' --exclude 'nuvio-web/node_modules' --exclude 'nuvio-web/build' \
  ./ "$TARGET:tv-remote/"

# The TV already trusts the key the Mac paired with: reuse it, so the TV doesn't ask again.
if [ -f tv.json ] && ! ssh "${SSH_OPTS[@]}" "$TARGET" 'test -f ~/tv-remote/data/tv/tv.json'; then
  echo "Copying the TV pairing..."
  scp -q "${SSH_OPTS[@]}" tv.json "$TARGET:tv-remote/data/tv/tv.json"
fi

echo "Building and starting (the first time takes a while)..."
ssh -t "${SSH_OPTS[@]}" "$TARGET" 'cd ~/tv-remote && (docker compose version >/dev/null 2>&1 && docker compose up -d --build || docker-compose up -d --build)'
HOST="${TARGET#*@}"
echo
echo "Done. On your phone, open http://$HOST:3000 and sign in with your Nuvio account."
