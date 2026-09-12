// Deterministic regression tests for the chime controller's pure policy and
// settings logic (ChimeLogic.js). Runs under node:test; the QML pragma line
// is stripped and the library is evaluated in a vm context so no QML runtime
// is needed.
//
// These defend observable contracts: the strict complete v4 settings schema
// (version plus all five typed, bounded fields, the sounds map requiring
// every event mapped to a catalog sound id), v3 migration (every existing
// field preserved, the sounds map seeded with the cues 0.3.0 played), v2
// migration (agentInputEnabled carried over verbatim into
// notificationsEnabled), safe v1 migration (notifications off), invalid
// reload preservation (mute must survive a malformed file), the
// persisted-settings roundtrip feeding playback eligibility, the generic
// notification event naming with no agent-named aliases left in the public
// surface, the per-event sound catalog and resolution helpers, and the two
// independent automatic-playback gate policies consumed by
// ChimeController.playEvent/playNotificationEvent. Preview gating and the
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

// A complete v4 settings file; pass overrides to mutate or drop keys
// (undefined values are omitted by JSON.stringify).
function file(overrides) {
  return JSON.stringify({ version: 4, enabled: true, volume: 0.5, desktopEnabled: true, notificationsEnabled: true, sounds: Logic.defaultEventSounds(), ...overrides })
}

// A complete v2 settings file (the agentInputEnabled schema).
function v2File(overrides) {
  return JSON.stringify({ version: 2, enabled: true, volume: 0.5, desktopEnabled: true, agentInputEnabled: true, ...overrides })
}

// A complete v1 settings file (the alpha-1 schema).
function legacyFile(overrides) {
  return JSON.stringify({ version: 1, enabled: true, volume: 0.5, desktopEnabled: true, ...overrides })
}

// ---------------------------------------------------------------- settings


test("parseSettings accepts a complete valid v4 file", () => {
  const r = Logic.parseSettings(file({ enabled: false, volume: 0.2, desktopEnabled: true, notificationsEnabled: false, sounds: { ...Logic.defaultEventSounds(), windowOpened: "bell" } }))
  assert.equal(r.ok, true)
  assert.deepEqual(plain(r.settings), { enabled: false, volume: 0.2, desktopEnabled: true, notificationsEnabled: false, sounds: { ...Logic.defaultEventSounds(), windowOpened: "bell" } })
})

test("parseSettings rejects incomplete v4 files: every key is required", () => {
  for (const missing of ["version", "enabled", "volume", "desktopEnabled", "notificationsEnabled", "sounds"]) {
    const r = Logic.parseSettings(file({ [missing]: undefined }))
    assert.equal(r.ok, false, missing + " must be required")
  }
})

test("parseSettings rejects invalid sounds maps", () => {
  // A missing event, a stale sound id, a non-string value, and a non-object
  // map each reject the whole file: sounds never partially apply.
  assert.equal(Logic.parseSettings(file({ sounds: {} })).ok, false)
  assert.equal(Logic.parseSettings(file({ sounds: { ...Logic.defaultEventSounds(), windowOpened: "power-plug" } })).ok, false)
  assert.equal(Logic.parseSettings(file({ sounds: { ...Logic.defaultEventSounds(), volumeUp: 7 } })).ok, false)
  assert.equal(Logic.parseSettings(file({ sounds: [] })).ok, false)
  assert.equal(Logic.parseSettings(file({ sounds: null })).ok, false)
  // A path traversal or absolute path is not a catalog id: rejected.
  assert.equal(Logic.parseSettings(file({ sounds: { ...Logic.defaultEventSounds(), windowClosed: "/etc/passwd" } })).ok, false)
})

test("parseSettings rejects invalid types and out-of-range volume", () => {
  assert.equal(Logic.parseSettings(file({ enabled: "true" })).ok, false)
  assert.equal(Logic.parseSettings(file({ desktopEnabled: 1 })).ok, false)
  assert.equal(Logic.parseSettings(file({ notificationsEnabled: "yes" })).ok, false)
  assert.equal(Logic.parseSettings(file({ volume: 1.5 })).ok, false)
  assert.equal(Logic.parseSettings(file({ volume: -0.1 })).ok, false)
  assert.equal(Logic.parseSettings(file({ volume: "0.5" })).ok, false)
  assert.equal(Logic.parseSettings(file({ volume: null })).ok, false)
})

test("parseSettings rejects unsupported versions", () => {
  assert.equal(Logic.parseSettings(file({ version: 5 })).ok, false)
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
  assert.deepEqual(plain(r.settings), plain({ enabled: true, volume: 0.5, desktopEnabled: true, notificationsEnabled: true, sounds: Logic.defaultEventSounds() }))
})

// An agentInputEnabled key inside a v4 file is an unknown key, ignored for
// forward compatibility: the v4 schema no longer has that switch.
test("parseSettings ignores a stray agentInputEnabled key in a v4 file", () => {
  const r = Logic.parseSettings(file({ agentInputEnabled: false }))
  assert.equal(r.ok, true)
  assert.deepEqual(plain(r.settings), plain({ enabled: true, volume: 0.5, desktopEnabled: true, notificationsEnabled: true, sounds: Logic.defaultEventSounds() }))
})

// ------------------------------------------------------------ v2 migration

test("complete v2 file migrates: every field preserved, agentInputEnabled carried over verbatim", () => {
  const r = Logic.parseSettings(v2File({ enabled: false, volume: 0.2, desktopEnabled: true, agentInputEnabled: true }))
  assert.equal(r.ok, true)
  assert.deepEqual(plain(r.settings), plain({ enabled: false, volume: 0.2, desktopEnabled: true, notificationsEnabled: true, sounds: Logic.defaultEventSounds() }))
})

test("complete v2 file with the switch off migrates with notifications off", () => {
  const r = Logic.parseSettings(v2File({ agentInputEnabled: false }))
  assert.equal(r.ok, true)
  assert.deepEqual(plain(r.settings), plain({ enabled: true, volume: 0.5, desktopEnabled: true, notificationsEnabled: false, sounds: Logic.defaultEventSounds() }))
})

test("incomplete v2 file is rejected like any malformed file", () => {
  for (const missing of ["version", "enabled", "volume", "desktopEnabled", "agentInputEnabled"]) {
    const r = Logic.parseSettings(v2File({ [missing]: undefined }))
    assert.equal(r.ok, false, missing + " must be required in v2 too")
  }
  assert.equal(Logic.parseSettings(v2File({ volume: 2 })).ok, false)
  assert.equal(Logic.parseSettings(v2File({ enabled: 1 })).ok, false)
  assert.equal(Logic.parseSettings(v2File({ agentInputEnabled: "yes" })).ok, false)
})

// ------------------------------------------------------------ v1 migration

test("complete v1 file migrates: every field preserved, notifications off", () => {
  const r = Logic.parseSettings(legacyFile({ enabled: false, volume: 0.2, desktopEnabled: true }))
  assert.equal(r.ok, true)
  assert.deepEqual(plain(r.settings), plain({ enabled: false, volume: 0.2, desktopEnabled: true, notificationsEnabled: false, sounds: Logic.defaultEventSounds() }))
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
    settings: { enabled: false, volume: 0.2, desktopEnabled: true, notificationsEnabled: true, sounds: Logic.defaultEventSounds() }
  }
  // Malformed file: the decided mute survives.
  const malformed = Logic.decideSettings(current, { ok: false, error: "invalid JSON" })
  assert.equal(malformed.source, "preserved")
  assert.deepEqual(plain(malformed.settings), plain(current.settings))
  // Incomplete v4 file rejected by the strict parser: same preservation.
  const incomplete = Logic.parseSettings(file({ sounds: undefined }))
  assert.equal(incomplete.ok, false)
  const decision = Logic.decideSettings(current, incomplete)
  assert.equal(decision.source, "preserved")
  assert.deepEqual(plain(decision.settings), plain(current.settings))
})

test("valid file is adopted over current settings", () => {
  const current = {
    settingsReady: true,
    settings: { enabled: true, volume: 0.9, desktopEnabled: false, notificationsEnabled: true, sounds: Logic.defaultEventSounds() }
  }
  const decision = Logic.decideSettings(current, {
    ok: true,
    settings: { enabled: false, volume: 0.1, desktopEnabled: true, notificationsEnabled: false, sounds: { ...Logic.defaultEventSounds(), workspaceSwitched: "bell" } }
  })
  assert.equal(decision.source, "file")
  assert.deepEqual(plain(decision.settings), plain({ enabled: false, volume: 0.1, desktopEnabled: true, notificationsEnabled: false, sounds: { ...Logic.defaultEventSounds(), workspaceSwitched: "bell" } }))
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

function notificationGates() {
  return {
    settingsReady: true,
    enabled: true,
    notificationsEnabled: true,
    safetyReady: true,
    notificationReady: true,
    cooldownActive: false,
    playing: false
  }
}

test("persisted settings round-trip and drive playback eligibility", () => {
  // A muted file survives serialize -> parse and keeps both automatic kinds
  // blocked.
  const muted = { enabled: false, volume: 0.2, desktopEnabled: true, notificationsEnabled: true, sounds: Logic.defaultEventSounds() }
  const parsed = Logic.parseSettings(Logic.serializeSettings(muted))
  assert.equal(parsed.ok, true)
  assert.deepEqual(plain(parsed.settings), plain(muted))
  assert.equal(Logic.automaticBlockedReason({ ...gates(), ...parsed.settings }), "muted")
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), ...parsed.settings }), "muted")

  // An enabled file round-trips and passes every gate.
  const on = { enabled: true, volume: 0.5, desktopEnabled: true, notificationsEnabled: true, sounds: Logic.defaultEventSounds() }
  const parsedOn = Logic.parseSettings(Logic.serializeSettings(on))
  assert.equal(parsedOn.ok, true)
  assert.deepEqual(plain(parsedOn.settings), plain(on))
  assert.equal(Logic.automaticBlockedReason({ ...gates(), ...parsedOn.settings }), "")
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), ...parsedOn.settings }), "")
})

test("persisted per-event sounds survive serialize -> parse and drive resolution", () => {
  const custom = { enabled: true, volume: 0.5, desktopEnabled: true, notificationsEnabled: true, sounds: { ...Logic.defaultEventSounds(), notificationReceived: "bell", windowOpened: "complete" } }
  const parsed = Logic.parseSettings(Logic.serializeSettings(custom))
  assert.equal(parsed.ok, true)
  assert.deepEqual(plain(parsed.settings.sounds), plain(custom.sounds))
  // The customized assignments are what playback would resolve.
  assert.equal(Logic.eventSoundPath("notificationReceived", parsed.settings.sounds), ASSET_DIR + "bell.oga")
  assert.equal(Logic.eventSoundPath("windowOpened", parsed.settings.sounds), ASSET_DIR + "complete.oga")
  // Untouched events keep their defaults.
  assert.equal(Logic.eventSoundPath("powerConnected", parsed.settings.sounds), ASSET_DIR + "device-added.oga")
})

test("a none assignment persists, stays valid, and resolves to silence", () => {
  // "none" is a first-class catalog id: a file assigning it parses strictly
  // and round-trips byte-stable.
  const silent = { enabled: true, volume: 0.5, desktopEnabled: true, notificationsEnabled: true, sounds: { ...Logic.defaultEventSounds(), volumeUp: "none", notificationReceived: "none" } }
  const parsed = Logic.parseSettings(Logic.serializeSettings(silent))
  assert.equal(parsed.ok, true)
  assert.deepEqual(plain(parsed.settings.sounds), plain(silent.sounds))
  // Both assignments resolve to no path: silence, not the event default.
  assert.equal(Logic.eventSoundPath("volumeUp", parsed.settings.sounds), "")
  assert.equal(Logic.eventSoundPath("notificationReceived", parsed.settings.sounds), "")
  // Unrelated events keep their default cue.
  assert.equal(Logic.eventSoundPath("windowOpened", parsed.settings.sounds), ASSET_DIR + "device-added.oga")
  // "none" is never treated as stale by the id helper.
  assert.equal(Logic.eventSoundId("volumeUp", parsed.settings.sounds), "none")
})

test("serializeSettings always emits the complete v4 schema", () => {
  const text = Logic.serializeSettings({ enabled: true, volume: 0.5, desktopEnabled: false, notificationsEnabled: true, sounds: Logic.defaultEventSounds() })
  const parsed = JSON.parse(text)
  assert.deepEqual(plain(parsed), plain({
    version: 4,
    enabled: true,
    volume: 0.5,
    desktopEnabled: false,
    notificationsEnabled: true,
    sounds: Logic.defaultEventSounds()
  }))
  // A serialized v4 file must itself parse strictly.
  assert.equal(Logic.parseSettings(text).ok, true)
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
  // The post-exit cooldown never blocks automatic non-notification events: a
  // rapid repeated same-name event (a second workspaceSwitched arriving after
  // the previous child exited but while the cooldown is still active) must
  // stay eligible on the repeat — the desktop/system source state machines
  // already deduplicate non-transitions and the controller preempts a
  // running voice.
  const switched = gates()
  assert.equal(Logic.automaticBlockedReason(switched), "")
  assert.equal(Logic.automaticBlockedReason({ ...switched, cooldownActive: true }), "")
  // A notifications switch state is irrelevant to automatic playback: the
  // gate consumes the caller-configured fields only.
  assert.equal(Logic.automaticBlockedReason({ ...gates(), notificationsEnabled: false }), "")
  // Mute is reported before a safety loss: gate order is part of the policy.
  assert.equal(Logic.automaticBlockedReason({ ...gates(), enabled: false, safetyReady: false }), "muted")
  // The caller selects which adapter readiness gates automatic playback:
  // the gate consumes the caller-set eventReady. A present desktop adapter
  // does not substitute for an unready caller-selected source.
  assert.equal(Logic.automaticBlockedReason({ ...gates(), eventReady: true }), "")
  assert.equal(Logic.automaticBlockedReason({ ...gates(), eventReady: false, desktopReady: true }), "event source not ready")
})

// ------------------------------------------------- event classification

const ALL_EVENTS = ["windowOpened", "windowClosed", "workspaceSwitched", "notificationReceived", "volumeUp", "volumeDown", "powerConnected", "powerDisconnected"]
const ALL_SYSTEM_EVENTS = ["volumeUp", "volumeDown", "powerConnected", "powerDisconnected"]
const ASSET_DIR = "/usr/share/sounds/freedesktop/stereo/"

test("isValidEvent accepts every known event and rejects everything else", () => {
  for (const name of ALL_EVENTS)
    assert.equal(Logic.isValidEvent(name), true, name)
  for (const bad of ["", null, undefined, "volumeUpp", "PowerConnected", "unknown", 42])
    assert.equal(Logic.isValidEvent(bad), false, String(bad) + " must be rejected")
})

test("the four system events are classified as system events, and the notification event classification is generic", () => {
  for (const name of ALL_EVENTS)
    assert.equal(Logic.isSystemEvent(name), ALL_SYSTEM_EVENTS.includes(name), name)
  // The notification event is exactly the notification event, and system
  // events are never notification events.
  for (const name of ALL_SYSTEM_EVENTS)
    assert.equal(Logic.isNotificationEvent(name), false, name)
  assert.equal(Logic.isNotificationEvent("notificationReceived"), true)
  for (const bad of ["", null, undefined, "volumeUp", "agentNeedsInput", "PowerConnected"])
    assert.equal(Logic.isNotificationEvent(bad), false, String(bad))
})

// ---------------------------------------------------------- sound catalog

test("the catalog exposes every installed distinct freedesktop sound plus the local asset", () => {
  // Every catalog entry resolves: id, label; every entry except "none" has
  // a playable path.
  for (const id of Logic.SOUND_IDS) {
    const entry = Logic.SOUND_CATALOG[id]
    assert.ok(entry, id)
    if (id !== "none")
      assert.ok(entry.path !== "", id + " has a path")
    assert.ok(entry.label !== "", id + " has a label")
  }
  // The theme entries are the distinct .oga files of the installed theme
  // (18 after symlink canonicalization), plus the one local plugin asset,
  // plus the "none" silence option.
  assert.equal(Logic.SOUND_IDS.length, 20)
  assert.ok(Logic.SOUND_IDS.indexOf("agent-needs-input") !== -1)
  assert.ok(Logic.SOUND_IDS.indexOf("none") !== -1)
  assert.equal(Logic.SOUND_CATALOG.none.path, "")
  // Symlink aliases of the theme are not separate catalog entries: their
  // canonical target is.
  for (const alias of ["power-plug", "power-unplug", "dialog-error", "window-attention", "window-question", "screen-capture", "network-connectivity-established", "network-connectivity-lost"])
    assert.equal(Logic.SOUND_IDS.indexOf(alias), -1, alias + " is a symlink alias, not a catalog id")
})

test("isValidSound accepts catalog ids and rejects everything else", () => {
  for (const id of Logic.SOUND_IDS)
    assert.equal(Logic.isValidSound(id), true, id)
  assert.equal(Logic.isValidSound("none"), true)
  for (const bad of ["", null, undefined, "device-added.oga", "/usr/share/sounds/freedesktop/stereo/bell.oga", "../assets/agent-needs-input.wav", "bell ", "Bell", 42])
    assert.equal(Logic.isValidSound(bad), false, String(bad) + " must be rejected")
})

test("eventSoundPath resolves the assigned sound and falls back to the event default", () => {
  const sounds = { ...Logic.defaultEventSounds(), notificationReceived: "phone-incoming-call" }
  assert.equal(Logic.eventSoundPath("notificationReceived", sounds), ASSET_DIR + "phone-incoming-call.oga")
  assert.equal(Logic.eventSoundPath("windowOpened", sounds), ASSET_DIR + "device-added.oga")
  // A stale id (sound removed from the catalog) fails safe to the default.
  assert.equal(Logic.eventSoundPath("windowClosed", { windowClosed: "deleted-sound" }), ASSET_DIR + "device-removed.oga")
  assert.equal(Logic.eventSoundPath("windowClosed", null), ASSET_DIR + "device-removed.oga")
  assert.equal(Logic.eventSoundPath("unknownEvent", sounds), "")
  // The notification default is the relative local asset (resolved by the
  // controller through Qt.resolvedUrl).
  assert.equal(Logic.eventSoundPath("notificationReceived", null), "assets/agent-needs-input.wav")
  // The explicit "none" assignment is silence: an empty path, never a
  // fallback to the event default — and never confused with a stale id.
  assert.equal(Logic.eventSoundPath("windowOpened", { ...sounds, windowOpened: "none" }), "")
  assert.equal(Logic.eventSoundId("windowOpened", { ...sounds, windowOpened: "none" }), "none")
  assert.equal(Logic.eventSoundId("windowOpened", { windowOpened: "none" }), "none")
})

test("eventSoundId returns the assignment or the event default, never a stale id", () => {
  const sounds = { ...Logic.defaultEventSounds(), workspaceSwitched: "bell" }
  assert.equal(Logic.eventSoundId("workspaceSwitched", sounds), "bell")
  assert.equal(Logic.eventSoundId("windowOpened", sounds), "device-added")
  assert.equal(Logic.eventSoundId("windowOpened", { windowOpened: "stale" }), "device-added")
  assert.equal(Logic.eventSoundId("windowOpened", null), "device-added")
  assert.equal(Logic.eventSoundId("unknownEvent", sounds), "")
  // "none" survives as an assignment.
  assert.equal(Logic.eventSoundId("volumeUp", { volumeUp: "none" }), "none")
})

test("eventLabel maps every event id to a human-readable name and nothing else", () => {
  // Issue #9: display names like "Window Opened" for the panel, while the
  // serialized ids and IPC surface stay camelCase. Exactly one label per
  // EVENT_IDS member, in order.
  const ids = Logic.EVENT_IDS
  const labels = ids.map(id => Logic.eventLabel(id))
  assert.deepEqual(plain(labels), [
    "Window Opened",
    "Window Closed",
    "Workspace Switched",
    "Notification Received",
    "Volume Up",
    "Volume Down",
    "Power Connected",
    "Power Disconnected",
  ])
  // Labels are title-cased words separated by single spaces: no camelCase
  // or raw ids leak into display strings.
  for (const label of labels) {
    assert.match(label, /^[A-Z][a-z]+( [A-Z][a-z]+)*$/)
  }
  // Unknown or missing ids label as empty, never as raw input.
  assert.equal(Logic.eventLabel("unknownEvent"), "")
  assert.equal(Logic.eventLabel(""), "")
  assert.equal(Logic.eventLabel(null), "")
  assert.equal(Logic.eventLabel(undefined), "")
})

test("capability-safe safety-state parsers accept complete public state and fail closed", () => {
  assert.deepEqual(plain(Logic.parseDndState('{\"version\":3,\"dnd\":false}')), { valid: true, active: false })
  assert.deepEqual(plain(Logic.parseDndState('{\"dnd\":true}')), { valid: true, active: true })
  assert.deepEqual(plain(Logic.parseDndState('{}')), { valid: false, active: false })
  assert.deepEqual(plain(Logic.parseDndState('not json')), { valid: false, active: false })

  assert.deepEqual(plain(Logic.parseLockState(' false ')), { valid: true, active: false })
  assert.deepEqual(plain(Logic.parseLockState(' true ')), { valid: true, active: true })
  assert.deepEqual(plain(Logic.parseLockState('unavailable')), { valid: false, active: false })

  const activeIdle = { idle: false, inIdleCycle: true, screensaverStarted: false, screensaverWindows: 0 }
  const activeScreensaver = { idle: false, inIdleCycle: false, screensaverStarted: false, screensaverWindows: 1 }
  const activeProtocol = { idle: true, inIdleCycle: false, screensaverStarted: false, screensaverWindows: 0 }
  const activeLaunch = { idle: false, inIdleCycle: false, screensaverStarted: true, screensaverWindows: 0 }
  const inactive = { idle: false, inIdleCycle: false, screensaverStarted: false, screensaverWindows: 0 }
  assert.deepEqual(plain(Logic.parseIdleState(JSON.stringify(inactive))), { valid: true, active: false })
  for (const state of [activeIdle, activeScreensaver, activeProtocol, activeLaunch])
    assert.deepEqual(plain(Logic.parseIdleState(JSON.stringify(state))), { valid: true, active: true })
  assert.deepEqual(plain(Logic.parseIdleState('{\"idle\":false}')), { valid: false, active: false })
  assert.deepEqual(plain(Logic.parseIdleState(JSON.stringify({ ...inactive, screensaverWindows: -1 }))), { valid: false, active: false })
})

// The old agent-named public surface is gone: no event id, no helper, no
// asset constant. Only the migration grammar still spells the retired v2
// switch name, and only the retained WAV file path still carries its
// original filename.
test("the old agent-named public surface is removed, aliases included", () => {
  assert.equal(Logic.isValidEvent("agentNeedsInput"), false)
  assert.equal(Logic.assetPath("agentNeedsInput"), "")
  assert.equal(Logic.isAgentEvent, undefined)
  assert.equal(Logic.isNotificationEvent("agentNeedsInput"), false)
  assert.equal(Logic.agentInputBlockedReason, undefined)
  assert.equal(Logic.AGENT_ASSET, undefined)
  // The notification cue keeps the existing WAV at its original path.
  assert.equal(Logic.NOTIFICATION_ASSET, "assets/agent-needs-input.wav")
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

test("notification playback has its own independent gate policy", () => {
  assert.equal(Logic.notificationBlockedReason(notificationGates()), "")
  // Desktop activation, ui-sounds overlap, and desktop readiness never gate
  // the notification cue.
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), desktopEnabled: false }), "")
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), overlapBlocked: true }), "")
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), desktopReady: false }), "")
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), eventReady: false }), "")
  // Its own gates still apply, in order.
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), settingsReady: false }), "settings not ready")
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), enabled: false }), "muted")
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), notificationsEnabled: false }), "notification sounds disabled")
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), safetyReady: false }), "not safe")
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), notificationReady: false }), "notification source not ready")
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), cooldownActive: true }), "cooldown")
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), playing: true }), "busy")
  // Mute is reported before a safety loss: gate order is part of the policy.
  assert.equal(Logic.notificationBlockedReason({ ...notificationGates(), enabled: false, safetyReady: false }), "muted")
})
