// Deterministic regression tests for the chime controller's pure policy and
// settings logic (ChimeLogic.js). Runs under node:test; the QML pragma line
// is stripped and the library is evaluated in a vm context so no QML runtime
// is needed.
//
// These defend observable contracts: the strict complete settings schema
// (version plus all three typed, bounded fields), invalid/incomplete reload
// preservation (mute must survive a malformed file), the persisted-settings
// roundtrip feeding playback eligibility, and the automatic-playback gate
// policy consumed by ChimeController.playEvent. Preview gating and the
// Process reservation/cooldown lifecycle are inline in ChimeController.qml
// and are exercised by the parent's runtime probe, not by these pure tests.

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "ChimeLogic.js"), "utf8")
  .replace(/^\.pragma library\s*\n/, "")

const context = vm.createContext({})
vm.runInContext(source, context, { filename: "ChimeLogic.js" })
const Logic = context

// Values produced inside the vm realm carry that realm's prototypes; convert
// to plain host objects so deepEqual compares shape, not realm identity.
function plain(value) {
  return JSON.parse(JSON.stringify(value))
}

// A complete settings file; pass overrides to mutate or drop keys
// (undefined values are omitted by JSON.stringify).
function file(overrides) {
  return JSON.stringify({ version: 1, enabled: true, volume: 0.5, desktopEnabled: true, ...overrides })
}

// ---------------------------------------------------------------- settings

test("parseSettings accepts a complete valid file", () => {
  const r = Logic.parseSettings(file({ enabled: false, volume: 0.2, desktopEnabled: true }))
  assert.equal(r.ok, true)
  assert.deepEqual(plain(r.settings), { enabled: false, volume: 0.2, desktopEnabled: true })
})

test("parseSettings rejects incomplete files: every key is required", () => {
  for (const missing of ["version", "enabled", "volume", "desktopEnabled"]) {
    const r = Logic.parseSettings(file({ [missing]: undefined }))
    assert.equal(r.ok, false, missing + " must be required")
  }
})

test("parseSettings rejects invalid types and out-of-range volume", () => {
  assert.equal(Logic.parseSettings(file({ enabled: "true" })).ok, false)
  assert.equal(Logic.parseSettings(file({ desktopEnabled: 1 })).ok, false)
  assert.equal(Logic.parseSettings(file({ volume: 1.5 })).ok, false)
  assert.equal(Logic.parseSettings(file({ volume: -0.1 })).ok, false)
  assert.equal(Logic.parseSettings(file({ volume: "0.5" })).ok, false)
  assert.equal(Logic.parseSettings(file({ volume: null })).ok, false)
})

test("parseSettings rejects unsupported versions", () => {
  assert.equal(Logic.parseSettings(file({ version: 2 })).ok, false)
})

test("parseSettings rejects malformed JSON and non-object roots", () => {
  assert.equal(Logic.parseSettings("{not json").ok, false)
  assert.equal(Logic.parseSettings("").ok, false)
  assert.equal(Logic.parseSettings("[1,2]").ok, false)
  assert.equal(Logic.parseSettings("null").ok, false)
})

test("parseSettings ignores unknown keys for forward compatibility", () => {
  const r = Logic.parseSettings(file({ future: "x" }))
  assert.equal(r.ok, true)
  assert.deepEqual(plain(r.settings), { enabled: true, volume: 0.5, desktopEnabled: true })
})

// ------------------------------------------------- invalid reload preservation

test("invalid or incomplete reload preserves decided settings, especially mute", () => {
  const current = {
    settingsReady: true,
    settings: { enabled: false, volume: 0.2, desktopEnabled: true }
  }
  // Malformed file: the decided mute survives.
  const malformed = Logic.decideSettings(current, { ok: false, error: "invalid JSON" })
  assert.equal(malformed.source, "preserved")
  assert.deepEqual(plain(malformed.settings), current.settings)
  // Incomplete file rejected by the strict parser: same preservation.
  const incomplete = Logic.parseSettings(file({ volume: undefined }))
  assert.equal(incomplete.ok, false)
  const decision = Logic.decideSettings(current, incomplete)
  assert.equal(decision.source, "preserved")
  assert.deepEqual(plain(decision.settings), current.settings)
})

test("invalid first load falls back to defaults", () => {
  const decision = Logic.decideSettings(
    { settingsReady: false, settings: Logic.defaults() },
    { ok: false, error: "no settings file" }
  )
  assert.equal(decision.source, "defaults")
  assert.deepEqual(plain(decision.settings), plain(Logic.defaults()))
})

test("valid file is adopted over current settings", () => {
  const current = {
    settingsReady: true,
    settings: { enabled: true, volume: 0.9, desktopEnabled: false }
  }
  const decision = Logic.decideSettings(current, {
    ok: true,
    settings: { enabled: false, volume: 0.1, desktopEnabled: true }
  })
  assert.equal(decision.source, "file")
  assert.deepEqual(plain(decision.settings), { enabled: false, volume: 0.1, desktopEnabled: true })
})

// ------------------------------------------------- playback eligibility

function gates() {
  return {
    settingsReady: true,
    enabled: true,
    desktopEnabled: true,
    overlapBlocked: false,
    safetyReady: true,
    desktopReady: true,
    cooldownActive: false,
    playing: false
  }
}

test("persisted settings round-trip and drive playback eligibility", () => {
  // A muted file survives serialize -> parse and keeps automatic playback
  // blocked.
  const muted = { enabled: false, volume: 0.2, desktopEnabled: true }
  const parsed = Logic.parseSettings(Logic.serializeSettings(muted))
  assert.equal(parsed.ok, true)
  assert.deepEqual(plain(parsed.settings), muted)
  assert.equal(Logic.automaticBlockedReason({ ...gates(), ...parsed.settings }), "muted")

  // An enabled file round-trips and passes every gate.
  const on = { enabled: true, volume: 0.5, desktopEnabled: true }
  const parsedOn = Logic.parseSettings(Logic.serializeSettings(on))
  assert.equal(parsedOn.ok, true)
  assert.deepEqual(plain(parsedOn.settings), on)
  assert.equal(Logic.automaticBlockedReason({ ...gates(), ...parsedOn.settings }), "")
})

test("automatic playback requires every gate, first blocking gate wins", () => {
  assert.equal(Logic.automaticBlockedReason(gates()), "")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), settingsReady: false }), "settings not ready")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), enabled: false }), "muted")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), desktopEnabled: false }), "desktop sounds disabled")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), overlapBlocked: true }), "blocked by ui-sounds")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), safetyReady: false }), "not safe")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), desktopReady: false }), "desktop not ready")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), cooldownActive: true }), "cooldown")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), playing: true }), "busy")
  // Mute is reported before a safety loss: gate order is part of the policy.
  assert.equal(Logic.automaticBlockedReason({ ...gates(), enabled: false, safetyReady: false }), "muted")
})
