#!/bin/zsh
set -eu
cd -- "${0:A:h}"
build_dir="${HDMI_LAB_BUILD:-$PWD/build}"
print 'Installing only HDMI Lab 8ch and 16ch. This briefly restarts all Mac audio.'
print 'Quit Music and stop any HDMI Lab playback before continuing.'
for channels in 8 16; do
    /usr/bin/codesign --verify --strict --deep "$build_dir/HDMILab${channels}ch.driver"
done
python3 - <<'PY'
from Bridge import active_bridge_pid
if active_bridge_pid():
    raise SystemExit('Stop the running bridge with Stop-DTS.command first.')
PY
/usr/bin/sudo -v
backup_dir="$PWD/runtime/backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup_dir"
/usr/bin/sudo /bin/mkdir -p /Library/Audio/Plug-Ins/HAL
for channels in 8 16; do
    bundle="HDMILab${channels}ch.driver"
    destination="/Library/Audio/Plug-Ins/HAL/$bundle"
    staging="/Library/Audio/Plug-Ins/HAL/.${bundle}.staging-$$"
    /usr/bin/sudo /usr/bin/ditto "$build_dir/$bundle" "$staging"
    /usr/bin/sudo /usr/sbin/chown -R root:wheel "$staging"
    /usr/bin/sudo /bin/chmod -R go-w "$staging"
    if [[ -e "$destination" ]]; then
        /usr/bin/sudo /bin/mv "$destination" "$backup_dir/$bundle"
    fi
    /usr/bin/sudo /bin/mv "$staging" "$destination"
done
/usr/bin/sudo /usr/bin/killall coreaudiod
print 'Installed. Wait a few seconds, then open Audio MIDI Setup.'
print 'Set HDMI Lab 16ch and its Mirror to 48,000 Hz, 16-channel float PCM.'
print "Previous HDMI Lab bundles, if any: $backup_dir"
