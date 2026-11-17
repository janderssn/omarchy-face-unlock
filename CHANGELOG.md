# Changelog

## 0.4.0

A settings window, and three new settings.

- **Settings window.** Every setting now lives in a window of its own: the **Settings** button in the bar panel, a right click on the bar icon, or `omarchy-shell face-unlock settings`. The bar panel keeps the status and the two switches used most, Wake on approach and Lock on leave; **Use for sudo** moved to the window, and **Wait until you look** (`requireAttention`), until now only in the file, has a switch there.

- **Stay awake while you watch** (`keepAwake`). While the sensor sees you looking at the screen, Omarchy's screensaver and idle lock do not start, whatever is playing and whether or not you touch anything: a film in tablet mode no longer ends in the lock screen. It needs a working sensor that reports you present and attentive; with the sensor blind, unsure or broken, the idle timers run as before.
- **Any input ends the screensaver** (`screensaverInput`). Omarchy's screensaver ends on a typed character only. Now moving the pointer, a click, or a key like Shift ends it too, so it can be dismissed in tablet mode.
- **End the screensaver when the sensor sees you** (`screensaverPresence`): `"off"`, `"return"` (the default: when you sit down, or look back at the screen after looking away) or `"watching"` (whenever you are seen looking at the screen, which also ends one you start yourself after three seconds).

Run **Update system files** from the panel after updating (the system files are unchanged; it only records the new version).

## 0.3.3

- A presence sensor that has lost its detection settings is repaired by the service. On the ASUS PX13 (webcam `13D3:52B9`) the sensor's presence threshold and range sensitivity read 0 after some boots; it then saw nobody, through restarts, reboots and power-offs, until Windows wrote the settings again. The service now checks them when it starts and whenever the sensor has been silent for 20 s, and writes back the values Windows uses. It writes only to sensors it knows (one so far) and only when a setting reads 0, so values chosen on purpose stay.
- For that, the service may now open raw HID devices (`DeviceAllow=char-hidraw rw`).

Run **Update system files** from the panel after updating.

## 0.3.2

- A presence sensor that never started reporting (seen once, after a cold boot) stayed silent until the next sleep, and the laptop believed the seat was empty. The service now notices the silence and switches the sensor off and on again, waiting for the kernel to really power it down in between. Restarting the service did not do that.
- sudo now goes straight to the password prompt when your face is not recognized. With Howdy running beside the prompt (`workaround=native`), a missed face also failed the password check, so sudo said "try again" and scanned once more, about 15 seconds before you could type. The face scan now comes first (at most Howdy's timeout, 4 s), then the password prompt.
- The 0.3.2 presence watchdog did not revive the stuck sensor of 2026-11-15; only booting Windows did. It stays, since it is harmless while the sensor streams.

Run **Update system files** from the panel after updating; it rewrites `/etc/pam.d/sudo` when face unlock for sudo is on.

## 0.3.1

Fixes from a code review.

- `requireAttention: false` was ignored by the lock screen, which kept requiring attention.
- Changing a switch in the panel erased a `graceSeconds` set in the config file.
- Lock on leave gave up for the rest of an absence when a lock was skipped (Stay Awake, lid closed) or failed. It now retries every 15 seconds while nobody is there.
- A failing sensor left its last reading published as current, which could stop the session ever locking. The service now publishes "unknown" at once.

Run **Update system files** from the panel after updating.

## 0.3.0

- **Use for sudo** switch in the panel, for sudo and graphical admin prompts. Changing it asks for your password: the setting is the PAM files, so nothing running as you can switch it back on.
- sudo and admin prompts skip the face scan while the camera's privacy switch is on, and go straight to the password.
- Setup asks one question for sudo and admin prompts instead of two.

Run **Update system files** from the panel after updating.

## 0.2.0

- The panel says when the camera's privacy switch is on. Laptops often give no other sign of it.
- With the privacy switch on the presence sensor is blind and reported an empty seat, so the session locked under you. It now reports "unknown": no lock on leave, no wake, and no face scans until the switch is off.
- The panel has two switches, Wake on approach and Lock on leave. Requiring attention is a file-only setting.

Run **Update system files** from the panel after updating.

## 0.1.0

First version.

- Face unlock on the Omarchy lock screen through Howdy Next, scanning only while the screen is on.
- Presence sensing: wake on approach, lock on leave, and scanning only while you look at the screen.
- Bar icon and panel with the switches.
- One-step setup, update and uninstall of the system side.
