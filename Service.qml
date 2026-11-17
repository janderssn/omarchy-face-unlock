import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "Model.js" as Model

// The part of Face Unlock that runs all the time: it follows the presence
// sensor, wakes the lock screen when you sit down, locks the session when
// you have walked away, keeps it awake while you watch, and lets the
// screensaver go when you touch something or come back. The face recognition itself happens in the lock
// screen's PAM stack (see system/), not here.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string configDir: Quickshell.env("HOME") + "/.config/omarchy-face-unlock"
  readonly property string presencePath: "/run/omarchy-face-unlock/presence.json"

  // ---- settings ---------------------------------------------------------------
  // Kept in a file of their own, because the lock screen's scan gate reads
  // them too and it runs outside the shell.
  property var config: Model.parseConfig("")
  readonly property bool lockOnLeave: config.lockOnLeave
  readonly property int lockDelaySeconds: config.lockDelaySeconds
  readonly property bool wakeOnApproach: config.wakeOnApproach
  readonly property bool requireAttention: config.requireAttention
  readonly property bool keepAwake: config.keepAwake
  readonly property bool screensaverInput: config.screensaverInput
  readonly property string screensaverPresence: config.screensaverPresence

  function setOption(key, value) {
    var next = Model.parseConfig(JSON.stringify(config))
    if (!(key in next)) return false
    next[key] = value
    next = Model.parseConfig(JSON.stringify(next))
    if (JSON.stringify(next) === JSON.stringify(config)) return false
    config = next
    configFile.setText(Model.serializeConfig(next))
    return true
  }

  FileView {
    id: configFile
    path: root.configDir + "/config.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.config = Model.parseConfig(text())
    onLoadFailed: root.config = Model.parseConfig("")
    onFileChanged: reload()
  }

  // ---- presence ---------------------------------------------------------------
  property var presence: Model.parsePresence("")
  readonly property bool sensorWorking: presence.sensor === "ok"
  // true, false, or null while the sensor has not decided.
  readonly property var present: presence.present
  readonly property bool attentive: presence.attentive
  readonly property int distanceMm: presence.distanceMm
  readonly property double since: presence.since

  function applyPresence(text) {
    var before = presence
    var after = Model.parsePresence(text)
    presence = after
    if (after.present !== false) {
      leftAndLocked = false
      lockRetryPending = false
      lockRetryTimer.stop()
    }
    if (Model.arrived(before, after) && wakeOnApproach) wakeProcess.running = true
    if (screensaverSettled && Model.endsScreensaver(screensaverPresence, before, after)) stopScreensaver("presence")
    scheduleLock()
  }

  FileView {
    id: presenceFile
    path: root.presencePath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyPresence(text())
    onLoadFailed: root.applyPresence("")
    onFileChanged: reload()
  }

  // The daemon rewrites its file in place, which the watch above follows. A
  // restarted daemon makes a new file, which it does not; this picks that up,
  // and the first file after setup has installed the service.
  Timer {
    interval: 5000
    repeat: true
    running: true
    onTriggered: {
      presenceFile.reload()
      if (root.setupState !== "ready") root.refreshSetup()
    }
  }

  // ---- wake on approach -----------------------------------------------------------
  Process {
    id: wakeProcess
    command: [root.pluginDir + "/bin/wake-lock"]
  }

  // ---- lock on leave ---------------------------------------------------------------
  // Two things must both hold for the whole delay: the sensor sees nobody,
  // and nothing has been typed or moved. The second keeps a session in use
  // out of the sensor's view (docked, or you leaning back to watch something
  // that inhibits idle) from locking under you.
  property bool leftAndLocked: false
  // A lock was just declined or failed; nothing asks again until the retry
  // timer says so. Without this the presence file's regular reload, which
  // reschedules the lock, would ask again within seconds.
  property bool lockRetryPending: false

  function scheduleLock() {
    var wait = lockOnLeave ? Model.lockWaitMs(presence, lockDelaySeconds, Date.now() / 1000) : -1
    if (wait < 0 || leftAndLocked || lockRetryPending) {
      lockTimer.stop()
      return
    }
    lockTimer.interval = Math.max(1, wait)
    lockTimer.restart()
  }

  function lockIfGone() {
    if (!lockOnLeave || leftAndLocked || lockRetryPending) return
    var wait = Model.lockWaitMs(presence, lockDelaySeconds, Date.now() / 1000)
    if (wait < 0) return
    if (wait > 0) {
      scheduleLock()
      return
    }
    // Still in use: the idle monitor calls back here once input has stopped.
    if (!idleMonitor.isIdle) return
    leftAndLocked = true
    lockProcess.running = true
  }

  onLockOnLeaveChanged: scheduleLock()
  onLockDelaySecondsChanged: scheduleLock()

  Timer {
    id: lockTimer
    repeat: false
    onTriggered: root.lockIfGone()
  }

  IdleMonitor {
    id: idleMonitor
    enabled: root.lockOnLeave && root.sensorWorking
    timeout: root.lockDelaySeconds
    respectInhibitors: true
    onIsIdleChanged: if (isIdle) root.lockIfGone()
  }

  // The helper can decline (Stay Awake, lid closed) or fail. The session is
  // then still open with nobody at it, so ask again for as long as that lasts.
  Process {
    id: lockProcess
    command: [root.pluginDir + "/bin/lock-on-leave"]
    onExited: function(exitCode) {
      if (exitCode === 0) return
      root.leftAndLocked = false
      root.lockRetryPending = true
      lockRetryTimer.restart()
    }
  }

  Timer {
    id: lockRetryTimer
    interval: 15000
    repeat: false
    onTriggered: {
      root.lockRetryPending = false
      root.lockIfGone()
    }
  }

  // ---- keep awake while you watch -----------------------------------------------
  // While the sensor sees you looking at the screen, the session counts as
  // in use: no screensaver, no idle lock, whatever is playing and whether or
  // not you touch anything. An idle inhibitor needs a surface that is on
  // screen, so this keeps an invisible one-pixel window for it. Hyprland
  // (0.56) only honours an inhibitor asked for after its surface is showing,
  // so the window stays up and only the inhibitor comes and goes.
  readonly property bool holdingAwake: keepAwake && Model.watching(presence)
  property bool awakeWindowShown: false

  Timer {
    interval: 1000
    running: true
    repeat: false
    onTriggered: root.awakeWindowShown = true
  }

  PanelWindow {
    id: awakeWindow
    visible: true
    implicitWidth: 1
    implicitHeight: 1
    color: "transparent"
    anchors.top: true
    anchors.left: true
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.namespace: "face-unlock-awake"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  }

  IdleInhibitor {
    window: awakeWindow
    enabled: root.holdingAwake && root.awakeWindowShown
  }

  // ---- screensaver ----------------------------------------------------------------
  // Omarchy's screensaver is a terminal that ends on a typed character only:
  // not on Shift, a touchpad or a touch screen, so in tablet mode nothing
  // ends it. Here any input does, and so does the sensor seeing you return.
  // Omarchy takes the closed screensaver as activity and drops its idle lock.
  readonly property string screensaverClass: "org.omarchy.screensaver"
  property var screensaverWindows: ({})
  property int screensaverCount: 0
  // Starting the screensaver moves focus between monitors, which the
  // compositor reports as input; only input after this counts.
  readonly property int screensaverSettleMs: 3000
  property bool screensaverSettled: false

  function trackScreensaver(address, open) {
    var next = {}
    var count = 0
    for (var key in screensaverWindows) {
      if (key !== address) { next[key] = true; count++ }
    }
    if (open) { next[address] = true; count++ }
    screensaverWindows = next
    screensaverCount = count
    if (open) {
      screensaverSettled = false
      screensaverSettleTimer.restart()
    } else if (count === 0) {
      screensaverSettled = false
      screensaverSettleTimer.stop()
    }
  }

  function stopScreensaver(reason) {
    if (screensaverCount === 0 || stopScreensaverProcess.running) return
    console.log("face-unlock: stopping the screensaver (" + reason + ")")
    stopScreensaverProcess.running = true
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (name === "openwindow") {
        var open = event.parse(4)
        if (String(open[2] || "") === root.screensaverClass) root.trackScreensaver(String(open[0] || ""), true)
      } else if (name === "closewindow") {
        var address = String(event.parse(1)[0] || "")
        if (root.screensaverWindows[address]) root.trackScreensaver(address, false)
      }
    }
  }

  Timer {
    id: screensaverSettleTimer
    interval: root.screensaverSettleMs
    repeat: false
    onTriggered: {
      root.screensaverSettled = true
      // Already being watched as it came up.
      if (Model.endsScreensaver(root.screensaverPresence, root.presence, root.presence)) root.stopScreensaver("presence")
    }
  }

  // A swipe on the touchpad: see bin/pointer-moved for why the idle monitor
  // below does not cover it.
  Process {
    id: pointerProcess
    command: [root.pluginDir + "/bin/pointer-moved"]
    running: root.screensaverInput && root.screensaverSettled && root.screensaverCount > 0
    onExited: function(exitCode) { if (exitCode === 0) root.stopScreensaver("pointer") }
  }

  // Reports any input within a second, whatever inhibits idle.
  IdleMonitor {
    id: inputMonitor
    enabled: root.screensaverInput && root.screensaverCount > 0
    timeout: 1
    respectInhibitors: false
    onIsIdleChanged: if (!isIdle && root.screensaverSettled) root.stopScreensaver("input")
  }

  Process {
    id: stopScreensaverProcess
    command: [root.pluginDir + "/bin/stop-screensaver"]
  }

  // ---- settings window --------------------------------------------------------------
  // Everything that can be set, in a window of its own; the bar panel keeps
  // the status and the two switches used most.
  property bool settingsOpen: false

  function openSettings() {
    refreshSetup()
    settingsOpen = true
  }

  Loader {
    active: root.settingsOpen
    source: "Settings.qml"
    onLoaded: {
      item.service = root
      item.closed.connect(function() { root.settingsOpen = false })
    }
  }

  // ---- setup --------------------------------------------------------------------------
  // The lock screen integration and the sensor service are installed with
  // sudo by system/setup; the panel offers to run it when they are missing or
  // older than this plugin.
  property var setupStatus: null
  readonly property string setupState: Model.setupState(setupStatus)

  // Face unlock for sudo and admin prompts. The setting is root's (the PAM
  // files), so changing it goes through pkexec, which asks for the password.
  // What was asked for is held until setup's status agrees (-1: follow it),
  // so the switch moves at once and falls back if the prompt is cancelled.
  property int desiredPrompts: -1
  readonly property bool prompts: desiredPrompts === -1
    ? !!(setupStatus && setupStatus.prompts === true) : desiredPrompts === 1
  readonly property bool promptsBusy: desiredPrompts !== -1

  function setPrompts(on) {
    if (promptsBusy || promptsProcess.running) return
    desiredPrompts = on ? 1 : 0
    promptsProcess.command = ["pkexec", "/usr/local/lib/omarchy-face-unlock/prompts", on ? "on" : "off"]
    promptsProcess.running = true
  }

  Process {
    id: promptsProcess
    onExited: root.refreshSetup()
  }

  // A status read already under way may predate a change; read again after it.
  property bool refreshSetupAgain: false

  function refreshSetup() {
    if (setupProcess.running) refreshSetupAgain = true
    else setupProcess.running = true
  }

  function runSetup() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", root.pluginDir + "/system/setup install"])
  }

  Process {
    id: setupProcess
    command: [root.pluginDir + "/system/setup", "status"]
    stdout: StdioCollector {
      id: setupStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (root.refreshSetupAgain) {
        root.refreshSetupAgain = false
        root.refreshSetup()
        return
      }
      if (exitCode === 0) {
        try {
          root.setupStatus = JSON.parse(setupStdout.text)
        } catch (error) {
        }
      }
      if (!promptsProcess.running) root.desiredPrompts = -1
    }
  }

  // omarchy-shell face-unlock status
  IpcHandler {
    target: "face-unlock"

    function status(): string {
      return JSON.stringify({
        setup: root.setupState,
        prompts: root.prompts,
        sensor: root.presence.sensor,
        present: root.present,
        attentive: root.attentive,
        distanceMm: root.distanceMm,
        lockOnLeave: root.lockOnLeave,
        lockDelaySeconds: root.lockDelaySeconds,
        wakeOnApproach: root.wakeOnApproach,
        requireAttention: root.requireAttention,
        keepAwake: root.keepAwake,
        holdingAwake: root.holdingAwake,
        screensaverInput: root.screensaverInput,
        screensaverPresence: root.screensaverPresence,
        screensaverShowing: root.screensaverCount > 0
      })
    }

    function set(key: string, value: string): string {
      var parsed = value === "true" ? true : (value === "false" ? false : (isNaN(Number(value)) ? value : Number(value)))
      return root.setOption(key, parsed) ? "ok" : "unchanged"
    }

    function settings(): string {
      root.openSettings()
      return "ok"
    }
  }

  Component.onCompleted: {
    Quickshell.execDetached(["mkdir", "-p", root.configDir])
    refreshSetup()
  }
}
