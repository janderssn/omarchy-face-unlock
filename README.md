# Face Unlock for Omarchy

Unlock [Omarchy](https://omarchy.org/) with your face, the way Windows Hello works on a laptop:

- **Look at the lock screen and it unlocks.** It scans only while the screen is on, never in the dark.
- **Sit down and it wakes.** A presence sensor lights the locked screen as you arrive, so it can recognise you.
- **Walk away and it locks.**
- **It waits until you look.** With a sensor that reports attention, it scans only while you face the screen.
- Your face also works for `sudo` and graphical admin prompts, if you want it to.

The password always works. Nothing here can lock you out.

Face recognition is done by [Howdy Next](https://github.com/nathawatc/howdy-next) with the laptop's infrared camera. This plugin connects it to Omarchy's lock screen and adds the presence features.

## Requirements

- Omarchy 4.5 or later.
- An **infrared camera** (the kind sold as "Windows Hello" cameras). A normal webcam is refused: it can be fooled by a photo.
- No fingerprint reader in use. The lock screen has one hands-free slot, and a fingerprint reader keeps it; face unlock is then still set up for `sudo`.
- Optional: a **human-presence sensor** for wake on approach, lock on leave and attention. Without one, face unlock works and those switches are hidden.

Developed and tested on an ASUS ProArt PX13 (HN7306EA).

## Install

```bash
omarchy plugin add https://github.com/janderssn/omarchy-face-unlock.git --enable
```

Then click the face icon in the bar and choose **Set up face unlock**. A terminal opens, asks for your password, and:

1. installs Howdy from the AUR and its recognition models,
2. enrolls your face,
3. asks whether to use your face for `sudo` and admin prompts (the **Use for sudo** switch in the settings window changes it later),
4. connects face unlock to the lock screen,
5. starts the presence service, if the laptop has a sensor.

You can also run it yourself: `~/.config/omarchy/plugins/janderssn.face-unlock/system/setup install`.

After a plugin update the panel offers **Update system files**, which runs the same setup again.

## Using it

Lock the screen (Super + Ctrl + L) and look at it.

| Situation | What happens |
|---|---|
| You lock and stay seated | Nothing. It does not unlock again while you sit there; the screen goes dark after 5 seconds. |
| You press a key or touch the touchpad | The screen lights, it sees you and unlocks, usually within a second. |
| You come back and sit down | The screen lights by itself and it unlocks. |
| Someone else sits down | The screen lights and stays locked. |
| You walk away | The session locks after 30 seconds. |

The bar icon is bright while the laptop sees you and dim while it does not. Its panel shows what the sensor sees, the two switches used most and a **Settings** row.

### The camera privacy switch

Many laptops have a key that blanks the camera in hardware, often with no light to show its state. While it is on, the panel says **Camera privacy is on**, and face unlock and the presence features pause: the sensor looks through the same camera, so it cannot tell whether you are there. The lock screen, `sudo` and admin prompts skip the face scan and take the password. (Detecting the switch needs the presence service, so a laptop without a presence sensor still scans, and then falls back to the password.)

## Settings

The bar panel shows what the sensor sees and has the two switches used most, **Wake on approach** and **Lock on leave** (with its delay), the same two that Windows offers under Presence sensing. Everything else is in the settings window: the panel's **Settings** button, a right click on the bar icon, or `omarchy-shell face-unlock settings`.

**Use for sudo** turns face unlock for `sudo` and graphical admin prompts on or off. It asks for your password, because the setting lives in the PAM files (`/etc/pam.d/sudo` and `/etc/pam.d/polkit-1`) where only root can change it; a program running as you cannot switch it back on.

Turning it on asks for your password. Turning it off shows the same prompt, but your face answers it, since admin prompts still accept it at that moment.

The other settings are stored in `~/.config/omarchy-face-unlock/config.json`, which you can also edit; changes apply at once.

```json
{
  "wakeOnApproach": true,
  "lockOnLeave": true,
  "lockDelaySeconds": 30,
  "requireAttention": true,
  "keepAwake": true,
  "screensaverInput": true,
  "screensaverPresence": "return"
}
```

| Setting | Meaning |
|---|---|
| `wakeOnApproach` | Light the locked screen when you sit down. |
| `lockOnLeave` | Lock after you have been gone for `lockDelaySeconds` (10 to 600). |
| `requireAttention` | Scan for a face only while you look at the screen. Turn it off if unlocking is slow because the sensor misjudges where you look. |
| `keepAwake` | While the sensor sees you looking at the screen, hold off Omarchy's screensaver and idle lock. Needs a working sensor; when it is blind or unsure the idle timers run as usual. |
| `screensaverInput` | End Omarchy's screensaver on any input: moving the pointer, a click, or a key like Shift. By itself it ends on a typed character only, which leaves no way out in tablet mode. Works without a sensor. |
| `screensaverPresence` | When the sensor ends the screensaver: `"off"` never; `"return"` when you sit down, or look back at the screen after looking away; `"watching"` whenever it sees you looking at the screen, which also ends one you start yourself, three seconds in. |
| `graceSeconds` | Seconds after locking before the first scan (default 7). File only. |

From a script: `omarchy-shell face-unlock status` and `omarchy-shell face-unlock set lockDelaySeconds 60`.

### When it will not lock on leave

Locking needs both an empty seat and no keyboard or pointer input for the whole delay. It also holds off while:

- an app inhibits idle (a video playing),
- Omarchy's Stay Awake is on,
- the lid is closed (the sensor then sees the keyboard, not you).

## How it works

```
presence sensor ──> presenced (root) ──> /run/omarchy-face-unlock/presence.json
                                              │                    │
                              shell plugin (Service.qml)     lock-gate (PAM)
                              wake on approach               scan only when the screen
                              lock on leave                  is on and you are looking
```

**Lock screen.** Omarchy's lock runs a second, hands-free PAM stack (`omarchy-lock-fingerprint`) in a loop, meant for fingerprint readers, but only when `fprintd-list` reports an enrolled finger. Setup installs a stand-in `fprintd-list` in `/usr/local/bin` that reports one, and a PAM stack that runs Howdy between two checks (`system/lock-gate`): before the scan it waits for the screen to be on, the grace period to be over and you to be looking; after a match it checks the screen is still on. Real fingerprints always win: if fprintd has any enrolled, the stand-in passes the real answer through.

**Presence.** The sensor is a HID human-presence sensor, read through the kernel's `hid-sensor-prox` IIO driver. It only reports real values while its buffer is enabled, which needs root, so a small system service (`system/presenced`, Python, no dependencies) reads it, filters out its dropouts and publishes a JSON file. It also reads the camera's privacy control (one value, never a picture). Some sensors lose their detection settings and then see nobody (the ASUS PX13's does, until Windows writes them again); for a sensor it knows, the service writes them back through the sensor's raw HID node. The service is sandboxed: no network, read-only system, access to IIO, camera and raw HID devices only.

**Wake.** The lock only wakes on input, so the plugin sends it a bare Shift key press through Hyprland when you arrive.

**Updates.** Omarchy's updates delete the lock's PAM file when no real fingerprint is enrolled. A systemd path unit watches it and puts it back.

## What it installs

| Path | What |
|---|---|
| `/usr/local/lib/omarchy-face-unlock/` | The scan gates, the presence daemon, the sudo switch's helper, the PAM stack's master copy |
| `/usr/local/bin/fprintd-list` | Stand-in that makes the lock run its hands-free stack |
| `/etc/pam.d/omarchy-lock-fingerprint` | The lock screen's face unlock stack |
| `/etc/systemd/system/omarchy-face-unlock-*` | The presence service and the PAM file watcher |
| `/etc/pam.d/sudo`, `/etc/pam.d/polkit-1` | Two lines each while **Use for sudo** is on: the privacy gate and `pam_howdy.so` |

Root only ever runs the copies under `/usr/local`, never files from the plugin folder in your home directory.

## Security

Face unlock is a convenience, like Windows Hello's face sign-in: it is weaker than a good password. Howdy with an infrared camera resists photos and screens, but not a determined attacker with a 3D likeness. Use the password alone for anything that matters more than a locked laptop on your desk.

The presence state file is readable by every user on the machine.

## Uninstall

```bash
~/.config/omarchy/plugins/janderssn.face-unlock/system/setup uninstall
omarchy plugin remove janderssn.face-unlock
```

Howdy and your enrolled face are left installed; the uninstaller prints the commands to remove them.

## Troubleshooting

- **It does not scan at all.** Check the camera privacy switch (Fn + F10 on the PX13): the panel says "Camera privacy is on" while it is. `omarchy-shell lock status` should show `"fingerprint": true`.
- **Presence says "not running".** `systemctl status omarchy-face-unlock-presence` and `journalctl -u omarchy-face-unlock-presence`.
- **What does the sensor see?** `cat /run/omarchy-face-unlock/presence.json`.
- **It unlocked right after I locked.** Something woke the lock within the grace period and kept the screen on, for example a notification. Raise `graceSeconds`.

## Development

```bash
tests/run
```

Strings and settings reload as you save. A change to the QML needs `omarchy restart shell` when the plugin folder is a link to a checkout. Changes under `system/` need `system/setup install` again.

## License

MIT
