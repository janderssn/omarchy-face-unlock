# Changelog

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
