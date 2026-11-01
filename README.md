# F75 Music

An **unofficial** macOS app for the AULA F75 keyboard. AULA's configuration software is Windows-only; this app gives Mac users lighting effects, music sync and control of the keyboard's built-in effects.

> This is an independent community project. It is not affiliated with, endorsed by, or supported by AULA. "AULA" and "F75" are used only to say which keyboard this works with. Use it at your own risk.

## Features

- **Mixable effects, each with its own brightness**
  - Keyboard effects: Static, Breathing, Wave, Starry, Typing Ripple
  - Music effects: Spectrum, Beat Ripple, Pulse, Rain
- **Music sync** from your Mac's system audio, with no virtual audio driver
- **Presets** and colour palettes, plus speed, sensitivity and master brightness
- **Built-in effects:** switch between the 18 effects stored on the keyboard
- **Live preview** using the F75's key layout
- **Menu bar control**, so lighting keeps running when the window is closed

## Requirements

- macOS 13 or later. Tested on Apple Silicon; an Intel build is included but untested
- An AULA F75 connected by USB cable, 2.4 GHz dongle or Bluetooth

Tested only on one F75 (USB `258a:010c`, dongle `3554:fa09`, Bluetooth `3554:fa07`). Other keyboards are not supported.

## Install

1. Download the DMG from [Releases](https://github.com/raghavt20/aula-f75-macos/releases).
2. Drag **F75 Music** to **Applications**.
3. The app isn't notarized by Apple, so macOS blocks it the first time. Try to open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**.

### Permissions

| Permission | Why |
|---|---|
| **Input Monitoring** | Talk to the keyboard, and detect key presses for Typing Ripple |
| **Screen & System Audio Recording** | Capture system audio for music effects. The screen itself isn't used |

Quit and reopen the app after granting a permission. Audio and key presses are processed live and aren't stored or sent anywhere.

If a new version stops connecting, remove F75 Music from those two lists and grant access again.

## Connections

| Connection | Update rate | Notes |
|---|---|---|
| **USB cable** | About 50 frames/s | Best quality |
| **2.4 GHz dongle** | About 330 packets/s accepted by the receiver | Full-board effects. Use the **Wireless** slider to trade smoothness for detail |
| **Bluetooth** | About 33 packets/s | Reduced frames, so effects are simplified and ripples are smaller |

Built-in effects are drawn by the keyboard itself, so they stay smooth on any connection.

## Known limitations

- **App effects and built-in effects can't be combined.** While the app streams lighting, keys outside the frame go dark. The built-in effect returns when you stop.
- **Typing Ripple doesn't see keys while secure input is on,** for example in password fields or in iTerm with Secure Keyboard Entry enabled.
- **USB key positions aren't verified yet.** The key numbering was confirmed over 2.4 GHz only, so effects over the cable could be offset by one row.
- **Changing a built-in effect over Bluetooth** needs a lighting profile saved from an earlier cable or dongle connection. macOS drops some of the keyboard's Bluetooth replies, so the app can't read the live profile there. Any lighting settings changed since that save, such as with Fn keys, are overwritten.
- Only the built-in effect can be changed. Its brightness, speed and colour can't be set from the app yet.
- Not every built-in effect has been individually tested.

## Build from source

Requires the Xcode command line tools.

```sh
./build.sh       # builds "F75 Music.app"
./make-dmg.sh    # builds dist/F75-Music-1.0.dmg
```

Ad-hoc signed builds look like a new app to macOS each time, so permissions must be granted again after each rebuild. To avoid that, sign with a local certificate:

```sh
SIGN_ID="Your Certificate Name" ./build.sh
```

## Troubleshooting

- **Not connected:** check Input Monitoring, and make sure the keyboard is awake and not attached to a virtual machine.
- **Music effects don't react:** check Screen & System Audio Recording, then quit and reopen the app.
- **Logs:** `~/Library/Logs/F75Music.log`
- **Lighting profile backup:** `~/Library/Application Support/F75Music/led_profile_backup.bin`. To write it back to the keyboard, quit the app, connect by cable or dongle, and run:

  ```sh
  open "/Applications/F75 Music.app" --args --led-restore
  ```

## How it works

The USB HID protocol was worked out for interoperability, so that the keyboard can be used on macOS. This repository contains original code only, and no AULA software, firmware or artwork.

- **USB:** feature report `0x06` (520 bytes) carrying LED-indexed RGB frames
- **2.4 GHz and Bluetooth:** report `0x13` (20 bytes) carrying compact groups of `[R, G, B, count, keys…]`
- **Settings:** a 128-byte lighting profile, where byte 10 selects the built-in effect

This app doesn't update firmware.

## License

[MIT](LICENSE)
