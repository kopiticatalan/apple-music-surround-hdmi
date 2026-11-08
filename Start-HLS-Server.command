#!/bin/zsh
set -eu
cd -- "${0:A:h}" || exit 1
tv_args=()
has_tv=false
for argument in "$@"; do
    if [[ "$argument" == --tv || "$argument" == --tv=* ]]; then has_tv=true; fi
done
if ! $has_tv && [[ -z "${HLS_TV_IP:-}" && ! -f runtime/ACTIVE-HLS.json && ! -f runtime/SERVICE-HLS.json ]]; then
    read -r 'tv_ip?TV IP address: '
    tv_args=(--tv "$tv_ip")
fi
python3 -u HLSService.py --start "${tv_args[@]}" "$@"
