import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Model.js" as Model

// The part of Face Unlock that runs all the time: it follows the presence
// sensor, wakes the lock screen when you sit down and locks the session when
// you have walked away. The face recognition itself happens in the lock
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
        requireAttention: root.requireAttention
      })
    }

    function set(key: string, value: string): string {
      var parsed = value === "true" ? true : (value === "false" ? false : Number(value))
      return root.setOption(key, parsed) ? "ok" : "unchanged"
    }
  }

  Component.onCompleted: {
    Quickshell.execDetached(["mkdir", "-p", root.configDir])
    refreshSetup()
  }
}
