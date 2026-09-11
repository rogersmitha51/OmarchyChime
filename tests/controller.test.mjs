// Deterministic regression tests for the chime controller's pure policy and
// settings logic (ChimeLogic.js). Runs under node:test; the QML pragma line
// is stripped and the library is evaluated in a vm context so no QML runtime
// is needed.
//
// These defend observable contracts: the strict complete v2 settings schema
// (version plus all four typed, bounded fields), safe v1 migration (every
// existing field preserved, the new per-event switch off), invalid/incomplete
// reload preservation (mute must survive a malformed file), the
// persisted-settings roundtrip feeding playback eligibility, and the two
// independent automatic-playback gate policies consumed by
// ChimeController.playEvent/playAgentInputEvent. Preview gating and the
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

// A complete v2 settings file; pass overrides to mutate or drop keys
// (undefined values are omitted by JSON.stringify).
function file(overrides) {
  return JSON.stringify({ version: 2, enabled: true, volume: 0.5, desktopEnabled: true, agentInputEnabled: true, ...overrides })
}

// A complete v1 settings file (the alpha-1 schema).
function legacyFile(overrides) {
  return JSON.stringify({ version: 1, enabled: true, volume: 0.5, desktopEnabled: true, ...overrides })
}

// ---------------------------------------------------------------- settings

test("parseSettings accepts a complete valid v2 file", () => {
  const r = Logic.parseSettings(file({ enabled: false, volume: 0.2, desktopEnabled: true, agentInputEnabled: false }))
  assert.equal(r.ok, true)
  assert.deepEqual(plain(r.settings), { enabled: false, volume: 0.2, desktopEnabled: true, agentInputEnabled: false })
})

test("parseSettings rejects incomplete v2 files: every key is required", () => {
  for (const missing of ["version", "enabled", "volume", "desktopEnabled", "agentInputEnabled"]) {
    const r = Logic.parseSettings(file({ [missing]: undefined }))
    assert.equal(r.ok, false, missing + " must be required")
  }
})

test("parseSettings rejects invalid types and out-of-range volume", () => {
  assert.equal(Logic.parseSettings(file({ enabled: "true" })).ok, false)
  assert.equal(Logic.parseSettings(file({ desktopEnabled: 1 })).ok, false)
  assert.equal(Logic.parseSettings(file({ agentInputEnabled: "yes" })).ok, false)
  assert.equal(Logic.parseSettings(file({ volume: 1.5 })).ok, false)
  assert.equal(Logic.parseSettings(file({ volume: -0.1 })).ok, false)
  assert.equal(Logic.parseSettings(file({ volume: "0.5" })).ok, false)
  assert.equal(Logic.parseSettings(file({ volume: null })).ok, false)
})

test("parseSettings rejects unsupported versions", () => {
  assert.equal(Logic.parseSettings(file({ version: 3 })).ok, false)
  assert.equal(Logic.parseSettings(file({ version: 0 })).ok, false)
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
  assert.deepEqual(plain(r.settings), { enabled: true, volume: 0.5, desktopEnabled: true, agentInputEnabled: true })
})

// ------------------------------------------------------------ v1 migration

test("complete v1 file migrates: every field preserved, agent input off", () => {
  const r = Logic.parseSettings(legacyFile({ enabled: false, volume: 0.2, desktopEnabled: true }))
  assert.equal(r.ok, true)
  assert.deepEqual(plain(r.settings), { enabled: false, volume: 0.2, desktopEnabled: true, agentInputEnabled: false })
})

test("incomplete v1 file is rejected like any malformed file", () => {
  for (const missing of ["version", "enabled", "volume", "desktopEnabled"]) {
    const r = Logic.parseSettings(legacyFile({ [missing]: undefined }))
    assert.equal(r.ok, false, missing + " must be required in v1 too")
  }
  assert.equal(Logic.parseSettings(legacyFile({ volume: 2 })).ok, false)
  assert.equal(Logic.parseSettings(legacyFile({ enabled: 1 })).ok, false)
})

// ------------------------------------------------- invalid reload preservation

test("invalid or incomplete reload preserves decided settings, especially mute", () => {
  const current = {
    settingsReady: true,
    settings: { enabled: false, volume: 0.2, desktopEnabled: true, agentInputEnabled: true }
  }
  // Malformed file: the decided mute survives.
  const malformed = Logic.decideSettings(current, { ok: false, error: "invalid JSON" })
  assert.equal(malformed.source, "preserved")
  assert.deepEqual(plain(malformed.settings), current.settings)
  // Incomplete v2 file rejected by the strict parser: same preservation.
  const incomplete = Logic.parseSettings(file({ agentInputEnabled: undefined }))
  assert.equal(incomplete.ok, false)
  const decision = Logic.decideSettings(current, incomplete)
  assert.equal(decision.source, "preserved")
  assert.deepEqual(plain(decision.settings), current.settings)
})

test("valid file is adopted over current settings", () => {
  const current = {
    settingsReady: true,
    settings: { enabled: true, volume: 0.9, desktopEnabled: false, agentInputEnabled: true }
  }
  const decision = Logic.decideSettings(current, {
    ok: true,
    settings: { enabled: false, volume: 0.1, desktopEnabled: true, agentInputEnabled: false }
  })
  assert.equal(decision.source, "file")
  assert.deepEqual(plain(decision.settings), { enabled: false, volume: 0.1, desktopEnabled: true, agentInputEnabled: false })
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

function agentGates() {
  return {
    settingsReady: true,
    enabled: true,
    agentInputEnabled: true,
    safetyReady: true,
    agentInputReady: true,
    cooldownActive: false,
    playing: false
  }
}

test("persisted settings round-trip and drive playback eligibility", () => {
  // A muted file survives serialize -> parse and keeps both automatic kinds
  // blocked.
  const muted = { enabled: false, volume: 0.2, desktopEnabled: true, agentInputEnabled: true }
  const parsed = Logic.parseSettings(Logic.serializeSettings(muted))
  assert.equal(parsed.ok, true)
  assert.deepEqual(plain(parsed.settings), muted)
  assert.equal(Logic.automaticBlockedReason({ ...gates(), ...parsed.settings }), "muted")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), ...parsed.settings }), "muted")

  // An enabled file round-trips and passes every gate.
  const on = { enabled: true, volume: 0.5, desktopEnabled: true, agentInputEnabled: true }
  const parsedOn = Logic.parseSettings(Logic.serializeSettings(on))
  assert.equal(parsedOn.ok, true)
  assert.deepEqual(plain(parsedOn.settings), on)
  assert.equal(Logic.automaticBlockedReason({ ...gates(), ...parsedOn.settings }), "")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), ...parsedOn.settings }), "")
})

test("desktop automatic playback requires every desktop gate, first blocking gate wins", () => {
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

test("agent-input playback is independent of desktop gates", () => {
  assert.equal(Logic.agentInputBlockedReason(agentGates()), "")
  // Desktop activation, ui-sounds overlap, and desktop readiness never gate
  // the agent-input cue.
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), desktopEnabled: false }), "")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), overlapBlocked: true }), "")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), desktopReady: false }), "")
  // Its own gates still apply, in order.
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), settingsReady: false }), "settings not ready")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), enabled: false }), "muted")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), agentInputEnabled: false }), "agent input sounds disabled")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), safetyReady: false }), "not safe")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), agentInputReady: false }), "agent input not ready")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), cooldownActive: true }), "cooldown")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), playing: true }), "busy")
  // Mute is reported before a safety loss: gate order is part of the policy.
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), enabled: false, safetyReady: false }), "muted")
})
