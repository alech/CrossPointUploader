# CrossPoint Uploader

A tiny macOS app that joins the **CrossPoint-Reader** Wi-Fi and uploads an `.epub`
to the device's web server at `http://crosspoint.local/upload`. It then disconnects
from the CrossPoint wifi.

This is vibe-cauded using Claude Opus 4.8 but works for me. YMMV.

## Build

```bash
./build.sh
```

Produces `CrossPointUploader.app` (arm64, ad-hoc signed). Requires the Xcode
command-line toolchain (`swiftc`).

## Headless / CLI mode (no clicking)

Pass an `.epub` path and the app runs the whole sequence automatically —
join `CrossPoint-Reader` → upload → reconnect to your previous Wi-Fi → quit —
mirroring progress to the terminal and exiting `0` on success, `1` on failure:

```bash
./crosspoint-upload /path/to/book.epub
# or directly:
./CrossPointUploader.app/Contents/MacOS/CrossPointUploader /path/to/book.epub
```

Use `crosspoint-upload`, not `open --args`: `open` re-activates an *already
running* copy without passing the new file (that's why the earlier arg was
ignored). The launcher starts a fresh process every time.

Running with no argument (or double-clicking the app) opens the normal window.

## Use (interactive)

1. On the reader: **Home → File Transfer → Create Hotspot** (starts the web server).
2. Launch `CrossPointUploader.app`.
3. Drop an `.epub` onto the window (or click **Choose EPUB…**).
4. Leave **Wi-Fi SSID** as `CrossPoint-Reader` (open network, no password).
   Set **Device folder** to where you want the file (defaults to `/`, the SD-card root).
5. Click **Connect & Upload**.

The first run pops the macOS **Local Network** permission prompt — allow it.
When it finishes it **reconnects to whatever Wi-Fi network you were on before**
(recorded at the start; falls back to power-cycling the radio if the direct
rejoin doesn't take). Uncheck *Reconnect…* to stay on the reader's hotspot.

## How it talks to the device

Discovered from the CrossPoint firmware docs (`docs/webserver-endpoints.md`):

```
POST http://crosspoint.local/upload?path=/          # multipart/form-data, field name "file"
```

Equivalent to:

```bash
curl -X POST -F "file=@book.epub" "http://crosspoint.local/upload?path=/"
```

Wi-Fi switching uses `/usr/sbin/networksetup`; no admin password is needed to
join an open network.

## Files

- `CrossPointUploader.swift` — the whole app (SwiftUI + AppKit)
- `Info.plist` — bundle metadata + Local Network / ATS keys
- `build.sh` — compile, assemble the `.app`, ad-hoc sign
- `crosspoint-upload` — thin CLI wrapper for headless mode

## License

Released under [CC0 1.0](LICENSE) — public domain, no rights reserved.
