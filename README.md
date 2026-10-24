# RoomShot for iPhone

Native shell around the RoomShot web app. Adds a live LiDAR room scan (ARKit scene reconstruction, furniture removed) and a direct Bluetooth connection to Bosch GLM laser measures. Plan, section, 3D view and SketchUp (.dae) export come from the bundled web app in `Resources/web/index.html`.

## Build
Every push builds the app on GitHub's Mac machines (see `.github/workflows/build.yml`). The unsigned `RoomShot.ipa` is attached to each run under **Actions → latest run → Artifacts → RoomShot-ipa**.

## Install (Windows PC, free Apple ID)
1. Install Sideloadly from sideloadly.io, plus Apple's iTunes and iCloud from apple.com (not the Microsoft Store versions).
2. Plug in the iPhone, drag `RoomShot.ipa` into Sideloadly, enter your Apple ID, and click Start.
3. On the iPhone: Settings → General → VPN & Device Management → trust your Apple ID. Turn on Settings → Privacy & Security → Developer Mode if asked, and restart.
4. Free installs expire after 7 days. Re-run Sideloadly to refresh; your rooms stay on the phone.

## Files
- `project.yml` — XcodeGen project definition
- `Sources/` — Swift: app entry, web view bridge, Bluetooth, LiDAR scanner
- `Resources/web/index.html` — the RoomShot web app
