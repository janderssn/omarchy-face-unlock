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

test("a grace period set in the file survives the panel rewriting it", () => {
  const config = Model.parseConfig('{"graceSeconds":12,"lockOnLeave":true}')
  assert.equal(config.graceSeconds, 12)
  const rewritten = Model.parseConfig(Model.serializeConfig({ ...config, lockOnLeave: false }))
  assert.equal(rewritten.graceSeconds, 12)
  assert.equal(rewritten.lockOnLeave, false)
  assert.equal(Model.parseConfig('{"graceSeconds":0}').graceSeconds, 0)
  assert.equal(Model.parseConfig('{"graceSeconds":9999}').graceSeconds, Model.MAX_GRACE)
  for (const bad of ['{"graceSeconds":"7"}', '{"graceSeconds":-1}', '{"graceSeconds":null}', "{}"]) {
    assert.equal("graceSeconds" in Model.parseConfig(bad), false)
  }
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

test("watching needs a working sensor that sees you look", () => {
  assert.equal(Model.watching(Model.parsePresence(here)), true)
  assert.equal(Model.watching(Model.parsePresence(away)), false)
  assert.equal(Model.watching(Model.parsePresence("")), false)
  assert.equal(Model.watching(Model.parsePresence('{"version":1,"sensor":"ok","present":true,"attentive":false}')), false)
  assert.equal(Model.watching(Model.parsePresence('{"version":1,"sensor":"ok","present":null,"attentive":true}')), false)
  assert.equal(Model.watching(Model.parsePresence('{"version":1,"sensor":"error","present":true,"attentive":true}')), false)
})

test("returning means sitting down or looking back at the screen", () => {
  const lookingAway = Model.parsePresence('{"version":1,"sensor":"ok","present":true,"attentive":false}')
  const unknown = Model.parsePresence('{"version":1,"sensor":"ok","present":null}')
  assert.equal(Model.returned(Model.parsePresence(away), Model.parsePresence(here)), true)
  assert.equal(Model.returned(Model.parsePresence(away), lookingAway), true)
  assert.equal(Model.returned(unknown, Model.parsePresence(here)), true)
  assert.equal(Model.returned(lookingAway, Model.parsePresence(here)), true)
  assert.equal(Model.returned(Model.parsePresence(here), Model.parsePresence(here)), false)
  assert.equal(Model.returned(Model.parsePresence(here), lookingAway), false)
  assert.equal(Model.returned(Model.parsePresence(here), Model.parsePresence(away)), false)
  assert.equal(Model.returned(Model.parsePresence(away), Model.parsePresence("")), false)
})

test("the new settings have defaults and refuse nonsense", () => {
  const defaults = Model.parseConfig("")
  assert.deepEqual([defaults.keepAwake, defaults.screensaverInput, defaults.screensaverPresence], [true, true, "return"])
  const set = Model.parseConfig('{"keepAwake":false,"screensaverInput":"no","screensaverPresence":"watching"}')
  assert.deepEqual([set.keepAwake, set.screensaverInput, set.screensaverPresence], [false, true, "watching"])
  assert.equal(Model.parseConfig('{"screensaverPresence":"off"}').screensaverPresence, "off")
  assert.equal(Model.parseConfig('{"screensaverPresence":true}').screensaverPresence, "return")
  assert.equal(Model.parseConfig('{"screensaverPresence":"always"}').screensaverPresence, "return")
})

test("the sensor ends the screensaver as the setting says", () => {
  const sat = Model.parsePresence(here)
  const gone = Model.parsePresence(away)
  // Came back.
  assert.equal(Model.endsScreensaver("off", gone, sat), false)
  assert.equal(Model.endsScreensaver("return", gone, sat), true)
  assert.equal(Model.endsScreensaver("watching", gone, sat), true)
  // Was watching all along, as when you start it yourself.
  assert.equal(Model.endsScreensaver("return", sat, sat), false)
  assert.equal(Model.endsScreensaver("watching", sat, sat), true)
  // Nobody there.
  assert.equal(Model.endsScreensaver("watching", gone, gone), false)
  assert.equal(Model.endsScreensaver("watching", sat, gone), false)
})

test("setup state compares what is installed with this plugin's version", () => {
  assert.equal(Model.setupState(null), "unknown")
  assert.equal(Model.setupState({ version: "0.1.0", installed: "" }), "missing")
  assert.equal(Model.setupState({ version: "0.2.0", installed: "0.1.0" }), "outdated")
  assert.equal(Model.setupState({ version: "0.1.0", installed: "0.1.0" }), "ready")
})
