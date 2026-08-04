#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h}"
source_root="$repo_root/Sources"
resource_root="$repo_root/Resources"
destination="$HOME/Applications/Codex Account Switcher.app"
launch_agent="$HOME/Library/LaunchAgents/com.edihasaj.codex-account-switcher.plist"
label="com.edihasaj.codex-account-switcher"
build_root="$(mktemp -d "${TMPDIR%/}/codex-account-switcher.XXXXXX")"
staged_app="$build_root/Codex Account Switcher.app"
fix_dock=0

usage() {
  print "Usage: ./install.sh [--fix-dock]"
  print "  --fix-dock  Keep one official Codex Dock pin and remove launcher pins."
}

for argument in "$@"; do
  case "$argument" in
    --fix-dock) fix_dock=1 ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "Unknown option: $argument"; usage >&2; exit 2 ;;
  esac
done

if [[ -x /Applications/ChatGPT.app/Contents/MacOS/ChatGPT ]]; then
  codex_app="/Applications/ChatGPT.app"
elif [[ -x "$HOME/Applications/ChatGPT.app/Contents/MacOS/ChatGPT" ]]; then
  codex_app="$HOME/Applications/ChatGPT.app"
else
  print -u2 "The signed Codex desktop app (ChatGPT.app) was not found."
  exit 1
fi

codex_app_url="file://$codex_app/"
codex_icon="$codex_app/Contents/Resources/icon-chatgpt.icns"

cleanup() {
  [[ ! -d "$build_root" ]] || /bin/rm -rf -- "$build_root"
}
trap cleanup EXIT HUP INT TERM

trash_item() {
  local target="$1"
  [[ ! -e "$target" ]] && return
  if command -v trash >/dev/null 2>&1; then
    trash "$target"
  else
    /bin/rm -rf -- "$target"
  fi
}

mkdir -p "$staged_app/Contents/MacOS"
xcrun swiftc -O -framework AppKit -framework Carbon \
  "$source_root/CodexAccountSwitcher.swift" \
  -o "$staged_app/Contents/MacOS/CodexAccountSwitcher"
cp "$resource_root/Info.plist" "$staged_app/Contents/Info.plist"
xattr -cr "$staged_app"
codesign --force --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"

xcrun swiftc -O -framework AppKit \
  "$source_root/CodexLauncher.swift" \
  -o "$build_root/CodexLauncher"

stage_launcher() {
  local display_name="$1"
  local bundle_identifier="$2"
  local action="$3"
  local launcher_app="$build_root/$display_name.app"

  mkdir -p "$launcher_app/Contents/MacOS" "$launcher_app/Contents/Resources"
  cp "$build_root/CodexLauncher" "$launcher_app/Contents/MacOS/CodexLauncher"
  sed \
    -e "s|__DISPLAY_NAME__|$display_name|g" \
    -e "s|__BUNDLE_IDENTIFIER__|$bundle_identifier|g" \
    -e "s|__ACTION__|$action|g" \
    "$resource_root/Launcher-Info.plist" > "$launcher_app/Contents/Info.plist"
  cp "$codex_icon" "$launcher_app/Contents/Resources/AppIcon.icns"
  xattr -cr "$launcher_app"
  codesign --force --sign - "$launcher_app"
  codesign --verify --deep --strict "$launcher_app"
}

stage_launcher "Codex Primary" "com.edihasaj.codex-primary-launcher" "primary"
stage_launcher "Codex Secondary" "com.edihasaj.codex-secondary-launcher" "secondary"
stage_launcher "Codex Open Both" "com.edihasaj.codex-open-both-launcher" "both"

launchctl bootout "gui/$UID/$label" 2>/dev/null || true
trash_item "$destination"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
mv "$staged_app" "$destination"

for launcher_name in "Codex Primary" "Codex Secondary" "Codex Open Both"; do
  launcher_destination="$HOME/Applications/$launcher_name.app"
  trash_item "$launcher_destination"
  mv "$build_root/$launcher_name.app" "$launcher_destination"
done

sed "s|__HOME__|$HOME|g" \
  "$resource_root/com.edihasaj.codex-account-switcher.plist" \
  > "$build_root/launch-agent.plist"
plutil -lint "$build_root/launch-agent.plist"
cp "$build_root/launch-agent.plist" "$launch_agent"

if (( fix_dock )); then
  dock_plist="$build_root/dock.plist"
  defaults export com.apple.dock "$dock_plist" >/dev/null
  changed=0
  chatgpt_kept=0

  for index in {100..0}; do
    label_value=$(plutil -extract \
      "persistent-apps.$index.tile-data.file-label" raw -o - \
      "$dock_plist" 2>/dev/null) || continue
    url_value=$(plutil -extract \
      "persistent-apps.$index.tile-data.file-data._CFURLString" raw -o - \
      "$dock_plist" 2>/dev/null || true)

    case "$label_value" in
      ChatGPT)
        if [[ "$url_value" == "$codex_app_url" ]] && (( ! chatgpt_kept )); then
          chatgpt_kept=1
        else
          plutil -remove "persistent-apps.$index" "$dock_plist"
          changed=1
        fi
        ;;
      'Codex Primary'|'Codex Second'|'Codex Secondary'|'Codex Open Both')
        plutil -remove "persistent-apps.$index" "$dock_plist"
        changed=1
        ;;
    esac
  done

  if (( ! chatgpt_kept )); then
    next_index=0
    for index in {0..100}; do
      if plutil -extract "persistent-apps.$index" xml1 -o /dev/null \
        "$dock_plist" 2>/dev/null; then
        next_index=$((index + 1))
      fi
    done
    dock_entry='{"tile-data":{"file-data":{"_CFURLString":"'"$codex_app_url"'","_CFURLStringType":15},"file-label":"ChatGPT","file-type":41},"tile-type":"file-tile"}'
    plutil -insert "persistent-apps.$next_index" -json "$dock_entry" "$dock_plist"
    changed=1
  fi

  if (( changed )); then
    defaults import com.apple.dock "$dock_plist"
    killall Dock
  fi
fi

launchctl bootstrap "gui/$UID" "$launch_agent"
launchctl kickstart -k "gui/$UID/$label"

print "Installed: $destination"
print "Launchers: ~/Applications/Codex Primary.app, Codex Secondary.app, Codex Open Both.app"
print "Shortcuts: Option-Command-1 (Primary), Option-Command-2 (Secondary)"
(( fix_dock )) && print "Dock: cleaned and pinned to the official signed app"
