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
    eventReady: true,
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

test("automatic playback requires every caller-configured gate, first blocking gate wins", () => {
  assert.equal(Logic.automaticBlockedReason(gates()), "")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), settingsReady: false }), "settings not ready")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), enabled: false }), "muted")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), desktopEnabled: false }), "desktop sounds disabled")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), overlapBlocked: true }), "blocked by ui-sounds")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), safetyReady: false }), "not safe")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), eventReady: false }), "event source not ready")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), playing: true }), "busy")
  // The post-exit cooldown never blocks automatic non-agent events: a rapid
  // repeated same-name event (a second workspaceSwitched arriving after the
  // previous child exited but while the cooldown is still active) must stay
  // eligible on the repeat — the desktop/system source state machines already
  // deduplicate non-transitions and the controller preempts a running voice.
  const switched = gates()
  assert.equal(Logic.automaticBlockedReason(switched), "")
  assert.equal(Logic.automaticBlockedReason({ ...switched, cooldownActive: true }), "")
  // Mute is reported before a safety loss: gate order is part of the policy.
  assert.equal(Logic.automaticBlockedReason({ ...gates(), enabled: false, safetyReady: false }), "muted")
  // The caller selects which adapter readiness gates automatic playback:
  // the gate consumes the caller-set eventReady. A present desktop adapter
  // does not substitute for an unready caller-selected source.
  assert.equal(Logic.automaticBlockedReason({ ...gates(), eventReady: true }), "")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), eventReady: false, desktopReady: true }), "event source not ready")
})

// ------------------------------------------------------- event classification

const ALL_EVENTS = ["windowOpened", "windowClosed", "workspaceSwitched", "agentNeedsInput", "volumeUp", "volumeDown", "powerConnected", "powerDisconnected"]
const ALL_SYSTEM_EVENTS = ["volumeUp", "volumeDown", "powerConnected", "powerDisconnected"]
const ASSET_DIR = "/usr/share/sounds/freedesktop/stereo/"

test("isValidEvent accepts every known event and rejects everything else", () => {
  for (const name of ALL_EVENTS)
    assert.equal(Logic.isValidEvent(name), true, name)
  for (const bad of ["", null, undefined, "volumeUpp", "PowerConnected", "unknown", 42])
    assert.equal(Logic.isValidEvent(bad), false, String(bad) + " must be rejected")
})

test("the four system events are classified as system events, and the agent event classification is unchanged", () => {
  for (const name of ALL_EVENTS)
    assert.equal(Logic.isSystemEvent(name), ALL_SYSTEM_EVENTS.includes(name), name)
  // The agent-input event is still exactly the agent event, and system
  // events are never agent events.
  for (const name of ALL_SYSTEM_EVENTS)
    assert.equal(Logic.isAgentEvent(name), false, name)
  assert.equal(Logic.isAgentEvent("agentNeedsInput"), true)
  for (const bad of ["", null, undefined, "volumeUp", "PowerConnected"])
    assert.equal(Logic.isAgentEvent(bad), false, String(bad))
})

test("every system event maps to the stock freedesktop asset", () => {
  const expected = {
    volumeUp: ASSET_DIR + "audio-volume-change.oga",
    volumeDown: ASSET_DIR + "audio-volume-change.oga",
    powerConnected: ASSET_DIR + "power-plug.oga",
    powerDisconnected: ASSET_DIR + "power-unplug.oga"
  }
  for (const [name, asset] of Object.entries(expected))
    assert.equal(Logic.assetPath(name), asset, name)
})

// ---------------------------------------------------- player command shape

test("playerCommand builds a safe pw-play argv from asset and volume", () => {
  assert.deepEqual(plain(Logic.playerCommand("/tmp/event.oga", 0.5)), ["/usr/bin/pw-play", "--volume", "0.5", "/tmp/event.oga"])
  // Each argument is its own list entry: no shell, no quoting, so a
  // whitespace-containing asset path stays one argv element.
  assert.equal(Logic.playerCommand("dir with space/sound.oga", 0.25).length, 4)
  assert.deepEqual(plain(Logic.playerCommand("dir with space/sound.oga", 0.25)), ["/usr/bin/pw-play", "--volume", "0.25", "dir with space/sound.oga"])
  assert.equal(Logic.playerCommand("sound.oga", 0.35)[0], "/usr/bin/pw-play")
  assert.equal(Logic.playerCommand("sound.oga", 0.35)[1], "--volume")
  assert.equal(Logic.playerCommand("sound.oga", 0.35)[2], "0.35")
  assert.equal(Logic.playerCommand("sound.oga", 0.35)[3], "sound.oga")
})

test("playerCommand volume is the plugin's per-stream relative gain", () => {
  // The plugin volume is passed through as a relative pw-play stream gain;
  // it never inverts the sink, routes directly to ALSA, or bypasses the
  // system sink volume.
  assert.equal(Logic.playerCommand("/tmp/event.oga", 0.5)[2], "0.5")
  assert.equal(Logic.playerCommand("/tmp/event.oga", 1)[2], "1")
  assert.equal(Logic.playerCommand("/tmp/event.oga", 0)[2], "0")
})

test("persisted settings round-trip and drive playback eligibility", () => {
  assert.equal(Logic.agentInputBlockedReason(agentGates()), "")
  // Desktop activation, ui-sounds overlap, and desktop readiness never gate
  // the agent-input cue.
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), desktopEnabled: false }), "")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), overlapBlocked: true }), "")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), desktopReady: false }), "")
  assert.equal(Logic.agentInputBlockedReason({ ...agentGates(), eventReady: false }), "")
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
