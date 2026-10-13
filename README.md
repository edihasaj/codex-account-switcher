# Codex Account Switcher

A tiny native macOS menu-bar controller for running two isolated accounts in
the signed Codex desktop app.

It keeps the official app bundle unchanged. The Secondary profile launches a
separate process with its own Codex home and Electron data directory:

```text
Primary:   ~/.codex-primary    + ~/Library/Application Support/Codex
Secondary: ~/.codex-secondary  + ~/Library/Application Support/Codex Second
```

before you continue further you can check https://edihasaj.com/posts/two-codex-accounts-two-dock-icons-macos

## Features

- Open or focus Primary with `Option-Command-1`.
- Open or focus Secondary with `Option-Command-2`.
- Keep both running for background work.
- Open or quit either profile from the menu bar.
- Finder/Spotlight launchers for Primary, Secondary, and Open Both.
- Start the switcher automatically at login.
- Optional Dock cleanup that keeps one official Codex pin.

## Requirements

- macOS 14 or later.
- The signed Codex desktop app installed as `/Applications/ChatGPT.app` or
  `~/Applications/ChatGPT.app`.
- Xcode Command Line Tools (`xcode-select --install`).

## Install

```zsh
git clone https://github.com/edihasaj/codex-account-switcher.git
cd codex-account-switcher
./install.sh
```

To also remove duplicate/launcher Dock pins and retain one official app pin:

```zsh
./install.sh --fix-dock
```

On first Secondary launch, sign into the second account. Later launches reuse
that isolated profile.

## Usage

Use the menu-bar people icon, the keyboard shortcuts, or the three launchers in
`~/Applications`:

- `Codex Primary.app`
- `Codex Secondary.app`
- `Codex Open Both.app`

Focus switching does not quit the other profile. Use the menu's explicit Quit
commands when you want to stop one.

## Uninstall

```zsh
./uninstall.sh
```

Uninstalling leaves `~/.codex-primary`, `~/.codex-secondary`, and both desktop-data
directories intact.

## How it works

The switcher compiles locally with Apple's Swift compiler and is ad-hoc signed.
It launches the unchanged official app with `open -n`, setting `CODEX_HOME` and
`--user-data-dir` for the Secondary process. Small background launcher apps
send actions to the menu-bar controller through distributed notifications.

This is an independent utility, not an official OpenAI product. Multi-instance
desktop operation is not an upstream guarantee, so app updates may require
adjustments.

## Development

```zsh
zsh -n install.sh uninstall.sh
xcrun swiftc -typecheck -framework AppKit -framework Carbon Sources/CodexAccountSwitcher.swift
xcrun swiftc -typecheck -framework AppKit Sources/CodexLauncher.swift
plutil -lint Resources/*.plist
```

## CI

Hosted macOS validation runs only for pushes and pull requests targeting
`production`, or for an explicit manual dispatch with **Run paid macOS
validation** enabled. The checkbox defaults off. The Linux native-policy job
checks the workflow on every eligible run; a skipped macOS job is not native
proof. Run `node --test scripts/native-ci-policy.test.mjs` locally to verify
the workflow event guards without installing dependencies.

## License

MIT
