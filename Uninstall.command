#!/bin/zsh
set -eu
cd -- "${0:A:h}"
python3 StopBridge.py
print 'Removing only HDMI Lab 8ch and 16ch; all Mac audio will restart briefly.'
print 'Select your normal speakers in Sound settings after removal.'
/usr/bin/sudo -v
# Move to a local backup instead of deleting bundles.
backup_dir="$PWD/runtime/uninstalled/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup_dir"
for channels in 8 16; do
    bundle="HDMILab${channels}ch.driver"
    if [[ -e "/Library/Audio/Plug-Ins/HAL/$bundle" ]]; then
        /usr/bin/sudo /bin/mv "/Library/Audio/Plug-Ins/HAL/$bundle" "$backup_dir/$bundle"
    fi
done
/usr/bin/sudo /usr/bin/killall coreaudiod
print "Removed HDMI Lab. Bundles saved in $backup_dir"
print 'To undo the experimental Music preference, quit Music and run:'
print 'defaults delete com.apple.Music multichannelAudioStrategy'
print 'If you had a value before this experiment, restore that value instead.'
