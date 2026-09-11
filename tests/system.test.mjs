// Deterministic regression tests for the system event adapter's pure state
// machine (SystemLogic.js). Runs under node:test; the QML pragma line is
// stripped and the library is evaluated in a vm context so no QML runtime
// is needed.
//
// The tests exercise the real adapter contract: volume events carry the
// current sink id and a finite volume; power events carry a strict boolean.
// Sink identities are compared as strings (quickshell recreates PwNodeIface
// wrappers, so object identity is meaningless), volumes are judged only
// against the baseline of the current sink, and the two sources are fully
// independent.

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "SystemLogic.js"), "utf8")
  .replace(/^\.pragma library\s*\n/, "")

const context = vm.createContext({})
vm.runInContext(source, context, { filename: "SystemLogic.js" })
const Logic = context

test("EVENT_IDS is exactly the four system events", () => {
  // The vm sandbox gives the library a different realm, so cross-realm
  // arrays are compared element-wise rather than with deepEqual.
  const expected = ["volumeUp", "volumeDown", "powerConnected", "powerDisconnected"]
  assert.equal(Logic.EVENT_IDS.length, expected.length)
  for (let i = 0; i < expected.length; i++)
    assert.equal(Logic.EVENT_IDS[i], expected[i])
})

test("initial silence: unseeded change and repeated seeded baselines emit nothing", () => {
  const state = Logic.newState()

  // Unseeded volume change: a silent baseline, not an event.
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.5), "")
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.5), "")
  // Unseeded power change: a silent baseline, not an event.
  assert.equal(Logic.handlePowerChange(state, false), "")
  assert.equal(Logic.handlePowerChange(state, false), "")

  // A rise after the silent baseline emits volumeUp.
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.6), "volumeUp")
  // A fall emits volumeDown; a repeat stays silent.
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.4), "volumeDown")
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.4), "")
})

test("volume directions: rise emits volumeUp, fall emits volumeDown", () => {
  const state = Logic.newState()
  Logic.seedVolume(state, "sink-1", 0.5)
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.5001), "volumeUp")
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.4999), "volumeDown")
  // Equal after a change (the baseline always advances) stays silent.
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.4999), "")
})

test("equal or invalid volume readings are silent, never seeded", () => {
  const state = Logic.newState()

  // Equal readings are silent.
  Logic.seedVolume(state, "sink-1", 0.5)
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.5), "")

  // Invalid readings are silent and must not establish a baseline.
  const fresh = Logic.newState()
  for (const bad of [NaN, Infinity, -Infinity, null, undefined, "0.5", "x", {}, []]) {
    assert.equal(Logic.handleVolumeChange(fresh, "sink-1", bad), "", String(bad) + " must be silent")
    assert.equal(Logic.isVolumeSeeded(fresh), false, String(bad) + " must not seed")
  }

  // Invalid readings never poison an established baseline either.
  assert.equal(Logic.handleVolumeChange(state, "sink-1", NaN), "")
  assert.equal(Logic.currentVolume(state), 0.5)
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.6), "volumeUp")
})

test("sink identity reset: new id reseeds silently, stale sink readings are ignored", () => {
  const state = Logic.newState()
  Logic.seedVolume(state, "sink-1", 0.5)

  // A reading attributed to a different (stale) sink is silent — it must not
  // poison the current sink's volume, and a stale first reading does not
  // rebase the baseline onto the stale sink.
  assert.equal(Logic.handleVolumeChange(state, "sink-2", 0.9), "")
  assert.equal(Logic.currentSinkId(state), "sink-1")
  assert.equal(Logic.currentVolume(state), 0.5)

  // A real sink swap reseeds silently: the old sink's volume must not be
  // compared against the new sink's.
  assert.equal(Logic.resetSink(state, "sink-2"), true)
  assert.equal(Logic.handleVolumeChange(state, "sink-2", 0.9), "")
  assert.equal(Logic.handleVolumeChange(state, "sink-2", 0.9), "")
  // The new baseline is 0.9: a fall from it emits.
  assert.equal(Logic.handleVolumeChange(state, "sink-2", 0.8), "volumeDown")

  // Repeating the identity is a no-op: a live baseline survives.
  assert.equal(Logic.resetSink(state, "sink-2"), false)
  assert.equal(Logic.currentVolume(state), 0.8)
  assert.equal(Logic.handleVolumeChange(state, "sink-2", 0.85), "volumeUp")

  // Swapping back to the first sink silently reseeds against its own read.
  assert.equal(Logic.resetSink(state, "sink-1"), true)
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.3), "")
  // A stale reading from sink-2 arriving late is still ignored.
  assert.equal(Logic.handleVolumeChange(state, "sink-2", 0.9), "")
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.35), "volumeUp")
})

test("sink identity to none: a missing sink clears volume but keeps power", () => {
  const state = Logic.newState()
  Logic.seedVolume(state, "sink-1", 0.5)
  Logic.seedPower(state, true)

  // The default sink briefly becomes null during a swap; identity goes "".
  assert.equal(Logic.resetSink(state, ""), true)
  assert.equal(Logic.isVolumeSeeded(state), false)
  // While there is no sink, volume readings cannot be attributed: silent.
  assert.equal(Logic.handleVolumeChange(state, "", 0.7), "")
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.7), "")
  // The power baseline survives the sink gap.
  assert.equal(Logic.currentPower(state), true)
  assert.equal(Logic.handlePowerChange(state, true), "")

  // A new sink appears: silent reseed against its own read.
  assert.equal(Logic.resetSink(state, "sink-3"), true)
  assert.equal(Logic.handleVolumeChange(state, "sink-3", 0.7), "")
})

test("power mapping: false connects, true disconnects; non-booleans silent", () => {
  const state = Logic.newState()
  Logic.seedPower(state, false)
  assert.equal(Logic.handlePowerChange(state, false), "")
  assert.equal(Logic.handlePowerChange(state, true), "powerDisconnected")
  assert.equal(Logic.handlePowerChange(state, true), "")
  assert.equal(Logic.handlePowerChange(state, false), "powerConnected")
  assert.equal(Logic.handlePowerChange(state, false), "")
})

test("invalid power readings are silent and never seed", () => {
  const fresh = Logic.newState()
  for (const bad of [null, undefined, 0, 1, "true", {}, []]) {
    assert.equal(Logic.handlePowerChange(fresh, bad), "", String(bad) + " must be silent")
    assert.equal(Logic.isPowerSeeded(fresh), false, String(bad) + " must not seed")
  }
  assert.equal(Logic.seedPower(fresh, 0), false)
  assert.equal(Logic.seedPower(fresh, "true"), false)
  assert.equal(Logic.isPowerSeeded(fresh), false)
  assert.equal(Logic.seedPower(fresh, true), true)
})

test("source independence: one source seeded does not gate or poison the other", () => {
  const state = Logic.newState()

  // Volume fully functional without any power baseline.
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.5), "")
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.6), "volumeUp")
  assert.equal(Logic.isPowerSeeded(state), false)

  // Power fully functional without any volume baseline.
  const other = Logic.newState()
  assert.equal(Logic.handlePowerChange(other, false), "")
  assert.equal(Logic.handlePowerChange(other, true), "powerDisconnected")
  assert.equal(Logic.isVolumeSeeded(other), false)

  // Baseline seeds of one source never touch the other.
  Logic.seedPower(state, true)
  assert.equal(Logic.currentPower(state), true)
  // The volume baseline (0.6 from the rise above) is undisturbed: a repeat
  // is silent and a further rise still emits.
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.6), "")
  assert.equal(Logic.handleVolumeChange(state, "sink-1", 0.65), "volumeUp")

  // A sink identity reset keeps the power baseline intact; the new sink's
  // volume reseeds silently against its own read, and power keeps judging
  // its own transitions.
  assert.equal(Logic.resetSink(state, "sink-2"), true)
  assert.equal(Logic.currentPower(state), true)
  assert.equal(Logic.handlePowerChange(state, true), "")
  assert.equal(Logic.handlePowerChange(state, false), "powerConnected")
  assert.equal(Logic.handleVolumeChange(state, "sink-2", 0.7), "")
  assert.equal(Logic.handleVolumeChange(state, "sink-2", 0.75), "volumeUp")
})
