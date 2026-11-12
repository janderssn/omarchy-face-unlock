// Tests for Model.js. Run: tests/run
const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("settings fall back to defaults for anything missing or malformed", () => {
  assert.deepEqual(Model.parseConfig(""), Model.DEFAULTS)
  assert.deepEqual(Model.parseConfig("not json"), Model.DEFAULTS)
  assert.deepEqual(Model.parseConfig("[1]"), Model.DEFAULTS)
  assert.deepEqual(Model.parseConfig('{"lockOnLeave":"yes","wakeOnApproach":false}'),
    { ...Model.DEFAULTS, wakeOnApproach: false })
})

test("the lock delay is kept within sane bounds", () => {
  assert.equal(Model.parseConfig('{"lockDelaySeconds":1}').lockDelaySeconds, Model.MIN_LOCK_DELAY)
  assert.equal(Model.parseConfig('{"lockDelaySeconds":99999}').lockDelaySeconds, Model.MAX_LOCK_DELAY)
  assert.equal(Model.parseConfig('{"lockDelaySeconds":"abc"}').lockDelaySeconds, Model.DEFAULTS.lockDelaySeconds)
  assert.equal(Model.parseConfig('{"lockDelaySeconds":45.4}').lockDelaySeconds, 45)
})

test("settings survive a round trip", () => {
  const config = { ...Model.DEFAULTS, lockDelaySeconds: 60, requireAttention: false }
  assert.deepEqual(Model.parseConfig(Model.serializeConfig(config)), config)
})

const here = '{"version":1,"sensor":"ok","present":true,"attentive":true,"distance_mm":412,"since":100}'
const away = '{"version":1,"sensor":"ok","present":false,"attentive":false,"distance_mm":null,"since":200}'

test("presence is read from the daemon's file", () => {
  assert.deepEqual(Model.parsePresence(here),
    { sensor: "ok", present: true, attentive: true, distanceMm: 412, since: 100, cameraPrivacy: false })
  assert.deepEqual(Model.parsePresence(away),
    { sensor: "ok", present: false, attentive: false, distanceMm: 0, since: 200, cameraPrivacy: false })
})

test("with camera privacy on, nobody is known to be here or away", () => {
  const blind = Model.parsePresence(
    '{"version":1,"sensor":"ok","present":null,"attentive":false,"distance_mm":null,"since":null,"camera_privacy":true}')
  assert.equal(blind.cameraPrivacy, true)
  assert.equal(blind.present, null)
  // So it neither locks the session nor wakes the lock when privacy goes off.
  assert.equal(Model.lockWaitMs(blind, 30, 500), -1)
  assert.equal(Model.arrived(blind, Model.parsePresence(here)), false)
  assert.equal(Model.parsePresence('{"version":1,"sensor":"ok","present":true,"camera_privacy":null}').cameraPrivacy, false)
})

test("a missing, broken or foreign file means no sensor", () => {
  for (const text of ["", "{", "null", '{"version":2,"sensor":"ok","present":true}']) {
    const presence = Model.parsePresence(text)
    assert.equal(presence.sensor, "off")
    assert.equal(presence.present, null)
  }
  assert.equal(Model.parsePresence('{"version":1,"sensor":"missing","present":null}').sensor, "missing")
})

test("an undecided sensor is neither here nor away", () => {
  const presence = Model.parsePresence('{"version":1,"sensor":"ok","present":null,"attentive":true}')
  assert.equal(presence.present, null)
  assert.equal(presence.attentive, false)
})

test("arriving means going from an empty seat to a taken one", () => {
  const unknown = Model.parsePresence('{"version":1,"sensor":"ok","present":null}')
  assert.equal(Model.arrived(Model.parsePresence(away), Model.parsePresence(here)), true)
  assert.equal(Model.arrived(unknown, Model.parsePresence(here)), false)
  assert.equal(Model.arrived(Model.parsePresence(""), Model.parsePresence(here)), false)
  assert.equal(Model.arrived(Model.parsePresence(here), Model.parsePresence(here)), false)
})

test("the lock waits out the delay from the moment the seat emptied", () => {
  const gone = Model.parsePresence(away)
  assert.equal(Model.lockWaitMs(gone, 30, 210), 20000)
  assert.equal(Model.lockWaitMs(gone, 30, 230), 0)
  assert.equal(Model.lockWaitMs(gone, 30, 500), 0)
  assert.equal(Model.lockWaitMs(Model.parsePresence(here), 30, 500), -1)
  assert.equal(Model.lockWaitMs(Model.parsePresence(""), 30, 500), -1)
})

test("setup state compares what is installed with this plugin's version", () => {
  assert.equal(Model.setupState(null), "unknown")
  assert.equal(Model.setupState({ version: "0.1.0", installed: "" }), "missing")
  assert.equal(Model.setupState({ version: "0.2.0", installed: "0.1.0" }), "outdated")
  assert.equal(Model.setupState({ version: "0.1.0", installed: "0.1.0" }), "ready")
})
