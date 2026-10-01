# macOS Network

Small tools for seeing which Wi-Fi networks around you are worth joining, ranked
best first.

| Piece | What it is |
|---|---|
| **WiFi Rank** | Menu bar app with a ranked network list and a sortable window. |
| **wifirank** | The same ranking in the terminal. |
| **WiFiScanHelper** | Hidden background app that does the actual scanning for both. |

## Why there's a helper

Recent macOS hides the names of nearby Wi-Fi networks from command-line tools,
showing `<redacted>` instead. Running as administrator doesn't change that.
Apple's own engineers confirmed the rule: the program asking must have Location
Services permission *and* be a real app with a running event loop
([Apple Developer Forums](https://developer.apple.com/forums/thread/769950)).

So WiFiScanHelper is a tiny app with no icon or window. It holds the location
permission, scans, prints the results, and quits. WiFi Rank and `wifirank` both
just run it and format what it prints.

## Using WiFi Rank

| Do this on the menu bar icon | Get this |
|---|---|
| Click | Network list, best first |
| Option-click | Network list with full detail |
| Shift-click | The WiFi Rank window |
| Right-click / Control-click | Show/Hide window, Start at Login, Quit |

Opening the app from the Dock, Spotlight or the Applications folder also shows
the window. While the window is open the app sits in the Dock; closing it puts
it back in the menu bar only.

Both the list and the window split networks into **Known** (this Mac has joined
them before) and **Other**. In the window, click a column title to sort and hover
over it for an explanation.

## Using wifirank

```
wifirank            # one line per network name
wifirank --bssid    # every access point, grouped by router
```

## Reading the numbers

- **SNR**: how far the signal stands out above background noise. The best single
  guide to real speed, so everything is sorted by it. 25 or more is comfortable;
  under 10 will struggle.
- **Signal (dBm)**: raw strength, always negative; closer to zero is stronger.
  -50 excellent, -65 good, -75 weak, -85 barely usable. Used to break SNR ties.
- **Band**: 2.4G reaches further but is slower and more crowded; 5G is faster but
  weaker through walls.
- **Channel**: networks sharing a channel slow each other down.
- **Security**: approximate. Treat it as a rough hint.

Neither SNR nor signal can see how busy a network is or how fast its internet
connection is, so the top pick is the best radio link, not necessarily the
fastest internet.

## Building and installing

```
./build.sh                 # build both apps into ./build
./build.sh install         # build, then install WiFi Rank and wifirank
./build.sh install-helper  # also replace the installed helper
```

Quit WiFi Rank before installing (right-click its icon → Quit WiFi Rank).

The apps are self-signed, so macOS treats every rebuild as a new app. For the
helper that means it asks for location access again, which is why replacing it
is a separate step. Rebuild it only when its code has changed.

Installed locations:

```
~/Applications/WiFi Rank.app
~/.local/libexec/WiFiScanHelper.app
~/.local/bin/wifirank
```

## Checking changes without opening anything

```
"build/WiFi Rank.app/Contents/MacOS/wifirank" --print                       # one scan, as text
"build/WiFi Rank.app/Contents/MacOS/wifirank" --render menu.png [--dark] [--detailed]
"build/WiFi Rank.app/Contents/MacOS/wifirank" --render-window win.png [--dark] [--sort snr]
"build/WiFi Rank.app/Contents/MacOS/wifirank" --render-icon icon.png
```

## Things that were tried and don't work

- **Joining a network from the app.** macOS's `networksetup -setairportnetwork`
  fails with error -3900 even when given the password, and macOS never shares its
  saved Wi-Fi passwords with other apps. Connecting is left to the system Wi-Fi
  menu. The helper still contains an unused `--join` mode.
- **⌘-click on the menu bar icon.** macOS keeps ⌘ for dragging menu bar icons
  around, so the click never reaches the app. That's why the window shortcut is
  Shift-click.
- **Double-click on the icon.** Possible, but every normal click would then wait
  about half a second to rule out a second click.
- **The old `airport` command.** Apple removed it in macOS 14.4.
