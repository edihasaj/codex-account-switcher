#!/bin/zsh

set -euo pipefail

label="com.edihasaj.codex-account-switcher"
launch_agent="$HOME/Library/LaunchAgents/$label.plist"

trash_item() {
  local target="$1"
  [[ ! -e "$target" ]] && return
  if command -v trash >/dev/null 2>&1; then
    trash "$target"
  else
    /bin/rm -rf -- "$target"
  fi
}

launchctl bootout "gui/$UID/$label" 2>/dev/null || true
trash_item "$launch_agent"
trash_item "$HOME/Applications/Codex Account Switcher.app"
trash_item "$HOME/Applications/Codex Primary.app"
trash_item "$HOME/Applications/Codex Secondary.app"
trash_item "$HOME/Applications/Codex Open Both.app"

print "Removed Codex Account Switcher and its launchers."
print "Codex profiles and desktop data were left untouched."
