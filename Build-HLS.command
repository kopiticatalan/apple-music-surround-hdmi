#!/bin/zsh
set -eu
cd -- "${0:A:h}" || exit 1
python3 HLSBridge.py --build-only
python3 build_player.py
