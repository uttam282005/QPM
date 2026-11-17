#!/usr/bin/env bash
# Install into an illogical-impulse (end-4) Quickshell config.
# Usage: ./install.sh [config-name]   (default: ii, i.e. ~/.config/quickshell/ii)
set -euo pipefail
cfg="${1:-ii}"
here="$(cd "$(dirname "$0")" && pwd)"
root="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/$cfg"
family="$root/panelFamilies/IllogicalImpulseFamily.qml"
states="$root/GlobalStates.qml"
target="$root/modules/ii/packageManager"

[[ -f $family && -f $states ]] || { echo "error: no illogical-impulse config at $root" >&2; exit 1; }
[[ -e $target && ! -L $target ]] && { echo "error: $target exists and is not a symlink; remove it first" >&2; exit 1; }
for dep in yay expac checkupdates pkexec kitty fish; do
    command -v "$dep" >/dev/null || echo "warning: '$dep' not found (see README)" >&2
done

ln -sfn "$here/packageManager" "$target"
grep -q 'packageManagerOpen' "$states" ||
    sed -i '0,/^    property bool /s//    property bool packageManagerOpen: false\n&/' "$states"
grep -q 'qs.modules.ii.packageManager' "$family" ||
    sed -i '0,/^import qs.modules.ii\./s//import qs.modules.ii.packageManager\n&/' "$family"
grep -q 'PackageManager {}' "$family" ||
    sed -i '0,/^    PanelLoader {/s//    PanelLoader { component: PackageManager {} }\n&/' "$family"

apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$apps"
sed "s/@CONFIG@/$cfg/" "$here/quickshell-package-manager.desktop" > "$apps/quickshell-package-manager.desktop"

echo "Installed into $root"
echo "Toggle with: qs -c $cfg ipc call packageManager toggle"
