# WiFi Rank

See which Wi-Fi networks around your Mac are worth joining, ranked best first.

| Piece | What it is |
|---|---|
| **WiFi Rank** | Menu bar app with a ranked network list, a window with a Networks tab and a Speed tab, and notifications. |
| **wifirank** | The same ranking in the terminal. It asks the app to do the scan. |

## Why it needs location access

Recent macOS hides the names of nearby Wi-Fi networks, showing `<redacted>`,
unless the program asking has Location Services permission *and* is a real app
with a running event loop. Running as administrator doesn't change that
([Apple Developer Forums](https://developer.apple.com/forums/thread/769950)).

WiFi Rank asks for location access the first time it scans. Click Allow once.
That's also why `wifirank` in the terminal doesn't scan by itself: it runs the
app in the background with `--json` and formats what comes back.

## Using WiFi Rank

| Do this on the menu bar icon | Get this |
|---|---|
| Click | Network list, best first |
| Option-click | Network list with full detail: SNR, Busy, signal and channel |
| Shift-click | The WiFi Rank window |
| Right-click / Control-click | Show/Hide window, Test Internet Speed, Better Network Alerts, Start at Login, Quit |

Opening the app from the Dock, Spotlight or the Applications folder also shows
the window. While the window is open the app sits in the Dock; closing it puts
it back in the menu bar only.

Each network shows its band (2.4G/5G) before its name. The window's columns
run Band, Network, Est. Speed, SNR, Busy, Width, Wi-Fi, Channel, Security: the
deciding numbers first, background detail last.

Networks are **ranked by estimated speed**: a cautious ceiling for the Wi-Fi link,
worked out from SNR, channel width and Wi-Fi generation (the standard Wi-Fi 6 rate
table, two streams, with a safety margin). SNR alone would rank a clean but narrow
2.4G 20 MHz network above a wide 5G 80 MHz one that is actually faster. Real links
usually run below the estimate, and it isn't your internet speed.

**Group into Clusters** (top of the Networks tab) switches from Known / Other
to one section per cluster: names broadcast by the same box, or by an office's
access points sharing a name, sit together under
"In one cluster · Office · 1 access point" or "In one cluster · 6 names · 2 access points",
followed by networks "On their own". It uses the same rules as `wifirank --bssid`.

Both the list and the window split networks into **Known** (this Mac has joined
them before) and **Other**. In the window, click a column title to sort and hover
over it for an explanation.

### Speed

The window's **Speed** tab measures the internet speed of the network you're
connected to, using macOS's built-in speed test (Apple's servers, nearest one
chosen automatically). A dial follows the live download reading; at the end it
shows download, upload, delay and responsiveness. A test takes about 20 seconds
and uses some data. Other networks can't be tested without joining them, and
macOS doesn't let apps do that.

Under the network's name, the Speed panel shows the **Wi-Fi link**: the speed
your Mac and the router are talking at right now (e.g. "1200 Mbps · Wi-Fi 6").
Compare it with the test result: when the link is much faster than your
internet, the internet connection is the limit, not the Wi-Fi.

**Test Internet Speed…** in the right-click menu opens a small window with the
same dial and starts a test straight away.

Every result is saved, and the Speed tab charts them:

- **By Network**: download and upload over time for the network you pick.
- **By Session**: a stretch of use, which can span several networks, with each
  point coloured by network. Tests less than 10 minutes apart count as one session.

Results live in `~/Library/Application Support/WiFi Rank/speed-history.json`.

### Notifications

- **Speed test finished**, but only if you're not looking at the speed view.
- **A faster network is nearby**: one of your known networks has an estimated
  speed at least 1.5× yours (and SNR of at least 20), using the average SNR of
  the last 3 scans for each, on two scans in a row. Averaging matters because
  SNR wobbles by about 6 on its own. Only one such alert at a time: no new one until you've dismissed the
  last, and never the same network twice within an hour. WiFi Rank scans
  quietly every 5 minutes for this. Turn it off with **Better Network Alerts**
  in the right-click menu.

## Using wifirank

```
wifirank            # one line per network name
wifirank --bssid    # every access point, grouped by physical router
```

`--bssid` groups radios that live in one box: addresses that share their first
five parts, or share their 4th and 5th parts with last parts close together, or
names that match once "2.4G"/"5G" is removed. A company router broadcasting six
names on two access points shows as one group: "6 names · 2 access points".

## Reading the numbers

- **SNR**: how far the signal stands out above background noise. The best single
  guide to how clean the signal is (the ranking combines it with width). **Green** 25 and above is
  enough for full speed, **orange** 10–24 works but may slow, **red** under 10
  will struggle.
- **Signal (dBm)**: raw strength, always negative; closer to zero is stronger.
  -50 excellent, -65 good, -75 weak, -85 barely usable. The window doesn't give
  it a column: hover an SNR value to see the signal and noise behind it, and
  whether a weak SNR comes from distance (weak signal) or interference (strong
  signal, noisy channel). The menu's Option view and `wifirank` still show it.
  Used to break SNR ties.
- **Band**: 2.4G reaches further but is slower and more crowded; 5G is faster but
  weaker through walls.
- **Width**: how wide a slice of airwaves the network uses. Wider carries more
  at once: 80 MHz is roughly four times 20 MHz. Usually 20 or 40 on 2.4G, 80 or
  160 on 5G.
- **Wi-Fi**: the generation the router supports (4, 5, 6, 6E, 7). Newer is
  faster and copes better with crowds. **Orange** 4 or older holds your speed
  back even with a good signal.
- **Channel**: networks sharing a channel slow each other down.
- **Busy**: how much of the channel's airtime is already in use, as the router
  reports it. Not IP addresses or the router's processor: think of a one-lane
  road and how often something is on it, counting the router, its devices,
  neighbouring networks on the same channel, and interference. Lower is better:
  **green** under 30% is comfortable, **orange** 30–59% is getting crowded,
  **red** 60% and over is crowded. Not every router reports it (shown as "–");
  hover a value to see devices connected and how many networks share the channel.
- **Security**: approximate. Only risky ones are coloured: **orange** Open (no
  password, no encryption) and **red** WEP (easy to crack).

In the Speed panel, **Responsiveness** is green for High, orange for Medium and
red for Low. Band and Channel stay uncoloured on purpose: they're facts rather
than good or bad.

SNR and signal can't see how fast a network's internet connection is, so the
top pick is the best radio link. Check Busy for how crowded it is, and the Speed
tab for the internet on the network you're on.

## Building and installing

```
./build.sh setup-signing   # once: make a personal signing certificate
./build.sh install         # build, then install WiFi Rank and wifirank
./build.sh                 # just build into ./build
```

The personal certificate gives every build the same identity, so macOS
remembers WiFi Rank's location permission when you rebuild. Without it the app
is signed ad hoc and macOS asks again after every build. The certificate is
self-made and only used on your Mac; it lives in its own keychain under
`~/.config/wifirank/`.

The icon (Wi-Fi arcs above the winner's step of a podium) is drawn in code;
`build.sh` turns it into `AppIcon.icns` inside the app on every build, so the app
icon and the menu bar icon always match.

Installed locations:

```
~/Applications/WiFi Rank.app
~/.local/bin/wifirank
```

If WiFi Rank is running while you install, quit it and open it again to use the
new version.

## Checking changes without opening anything

```
"build/WiFi Rank.app/Contents/MacOS/wifirank" --print        # one scan, as text
"build/WiFi Rank.app/Contents/MacOS/wifirank" --json         # one scan, as JSON
"build/WiFi Rank.app/Contents/MacOS/wifirank" --render menu.png [--dark] [--detailed]
"build/WiFi Rank.app/Contents/MacOS/wifirank" --render-window win.png [--dark] [--sort snr] [--tab speed] [--sample-networks]
    [--sample-history] [--history session] [--session-index N] [--speed-state testing|failed]
"build/WiFi Rank.app/Contents/MacOS/wifirank" --render-speed-window speed.png [--dark] [--sample-history] [--speed-state testing]
"build/WiFi Rank.app/Contents/MacOS/wifirank" --speed-test           # one real speed test, live readings printed
"build/WiFi Rank.app/Contents/MacOS/wifirank" --check-better-rule    # better-network rule against made-up scans
"build/WiFi Rank.app/Contents/MacOS/wifirank" --check-load           # which nearby routers report how busy they are
"build/WiFi Rank.app/Contents/MacOS/wifirank" --check-details        # Wi-Fi generation and width per router, current link rate
"build/WiFi Rank.app/Contents/MacOS/wifirank" --render-icon icon.png  # the app icon at 1024 pixels
"build/WiFi Rank.app/Contents/MacOS/wifirank" --render-menubar-icon bar.png
"build/WiFi Rank.app/Contents/MacOS/wifirank" --render-icon icon.png
```

## Things that were tried and don't work

- **Joining a network from the app.** macOS's `networksetup -setairportnetwork`
  fails with error -3900 even when given the password, and macOS never shares its
  saved Wi-Fi passwords with other apps. Connecting is left to the system Wi-Fi
  menu.
- **⌘-click on the menu bar icon.** macOS keeps ⌘ for dragging menu bar icons
  around, so the click never reaches the app. That's why the window shortcut is
  Shift-click.
- **Double-click on the icon.** Possible, but every normal click would then wait
  about half a second to rule out a second click.
- **The old `airport` command.** Apple removed it in macOS 14.4.

## Source files

| File | What's in it |
|---|---|
| `WiFiRank/main.swift` | Entry point: command-line modes, otherwise the menu bar app |
| `WiFiRank/WiFiRank.swift` | Scanning, the menu, the main window, the app itself |
| `WiFiRank/Speed.swift` | Running the speed test and keeping its history |
| `WiFiRank/SpeedViews.swift` | Dial panel, history chart, Speed tab, small speed window |
| `WiFiRank/Notifier.swift` | Notifications and the better-network rule |
| `WiFiRank/Icon.swift` | The podium icon: app icon at every size and the menu bar icon |
