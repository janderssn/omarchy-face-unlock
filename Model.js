// Pure logic for the Face Unlock plugin, kept free of QML so it can be tested
// with plain Node (tests/model.test.js).

var DEFAULTS = {
  lockOnLeave: true,
  lockDelaySeconds: 30,
  wakeOnApproach: true,
  requireAttention: true
}

var MIN_LOCK_DELAY = 10
var MAX_LOCK_DELAY = 600
// graceSeconds has no switch in the panel and no entry in DEFAULTS: it stays
// out of the file until someone writes it there, and the lock's scan gate
// supplies the default. It must survive the panel rewriting the file.
var MAX_GRACE = 120

function clampDelay(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return DEFAULTS.lockDelaySeconds
  return Math.max(MIN_LOCK_DELAY, Math.min(MAX_LOCK_DELAY, n))
}

// The settings file is the user's to edit, so nothing in it is trusted to
// have the right type; anything missing or malformed takes its default.
function parseConfig(text) {
  var raw = {}
  try {
    var parsed = JSON.parse(String(text || ""))
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) raw = parsed
  } catch (error) {
  }
  function flag(key) {
    return typeof raw[key] === "boolean" ? raw[key] : DEFAULTS[key]
  }
  var config = {
    lockOnLeave: flag("lockOnLeave"),
    lockDelaySeconds: raw.lockDelaySeconds === undefined ? DEFAULTS.lockDelaySeconds : clampDelay(raw.lockDelaySeconds),
    wakeOnApproach: flag("wakeOnApproach"),
    requireAttention: flag("requireAttention")
  }
  var grace = raw.graceSeconds
  if (typeof grace === "number" && isFinite(grace) && grace >= 0) {
    config.graceSeconds = Math.min(MAX_GRACE, Math.round(grace))
  }
  return config
}

function serializeConfig(config) {
  return JSON.stringify(parseConfig(JSON.stringify(config)), null, 2) + "\n"
}

var NO_SENSOR = { sensor: "off", present: null, attentive: false, distanceMm: 0, since: 0, cameraPrivacy: false }

// What the presence daemon published. `present` is true, false, or null while
// the sensor has not said enough to decide.
function parsePresence(text) {
  var raw
  try {
    raw = JSON.parse(String(text || ""))
  } catch (error) {
    return NO_SENSOR
  }
  if (!raw || typeof raw !== "object" || raw.version !== 1) return NO_SENSOR
  var ok = raw.sensor === "ok"
  var present = ok && typeof raw.present === "boolean" ? raw.present : null
  var distance = Number(raw.distance_mm)
  var since = Number(raw.since)
  return {
    sensor: ok ? "ok" : (raw.sensor === "missing" ? "missing" : "off"),
    present: present,
    attentive: present === true && raw.attentive === true,
    distanceMm: present === true && isFinite(distance) && distance > 0 ? Math.round(distance) : 0,
    since: isFinite(since) && since > 0 ? since : 0,
    // The camera's privacy switch is on; the sensor is blind while it is.
    cameraPrivacy: raw.camera_privacy === true
  }
}

// Someone sat down: the last thing seen was an empty seat, and now it is not.
function arrived(before, after) {
  return before.sensor === "ok" && before.present === false && after.present === true
}

// Milliseconds until the seat has been empty for the whole delay, or -1 when
// nobody is known to be away.
function lockWaitMs(presence, delaySeconds, nowSeconds) {
  if (presence.sensor !== "ok" || presence.present !== false || !(presence.since > 0)) return -1
  var left = presence.since + delaySeconds - nowSeconds
  return Math.max(0, Math.round(left * 1000))
}

// Which state the system side is in, from `setup status`.
function setupState(status) {
  if (!status || typeof status !== "object") return "unknown"
  if (!status.installed) return "missing"
  if (status.installed !== status.version) return "outdated"
  return "ready"
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULTS: DEFAULTS,
    MIN_LOCK_DELAY: MIN_LOCK_DELAY,
    MAX_LOCK_DELAY: MAX_LOCK_DELAY,
    MAX_GRACE: MAX_GRACE,
    clampDelay: clampDelay,
    parseConfig: parseConfig,
    serializeConfig: serializeConfig,
    parsePresence: parsePresence,
    arrived: arrived,
    lockWaitMs: lockWaitMs,
    setupState: setupState
  }
}
