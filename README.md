# HA Menubar

Your Home Assistant dashboard in a macOS menu bar popover, one click away. It is a live web view of the real dashboard, so every card, pop-up and hold gesture works as in the browser. Works best with a phone-width (about 390 px) dashboard.

- Left-click the house icon: dashboard (stays connected, opens instantly)
- Right-click: Reload, Open in Browser, Settings, Quit
- Reloads after wake; dark appearance; optional launch at login
- No token stored: you log in on Home Assistant's own page once and the session is kept

Requires macOS 14+.

## Install

Download `HAMenubar.zip` from [Releases](../../releases), unzip, move `HAMenubar.app` to Applications. The app is not notarized, so clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/HAMenubar.app
```

Or build it yourself (Xcode Command Line Tools are enough):

```sh
make app      # build/HAMenubar.app
make run      # build and launch
```

## Setup

On first launch, paste your dashboard URL, e.g. `https://homeassistant.local:8123/lovelace/0`, or just the server URL for the default dashboard. Then click the icon and log in.
