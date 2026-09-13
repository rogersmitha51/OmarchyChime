.pragma library

// Pure policy and settings logic for the chime sound controller.
//
// Everything here is free of QML dependencies so it can be exercised with
// node:test + vm (see tests/controller.test.mjs). ChimeController.qml owns
// the FileView/Process lifecycle and calls into these functions for parsing,
// validation, and playback policy.

var EVENT_IDS = ["windowOpened", "windowClosed", "workspaceSwitched", "notificationReceived", "volumeUp", "volumeDown", "powerConnected", "powerDisconnected"]

var EVENT_LABELS = {
  windowOpened: "Window Opened",
  windowClosed: "Window Closed",
  workspaceSwitched: "Workspace Switched",
  notificationReceived: "Notification Received",
  volumeUp: "Volume Up",
  volumeDown: "Volume Down",
  powerConnected: "Power Connected",
  powerDisconnected: "Power Disconnected"
}

// The four system events: volume and power-state cues driven by the session
// bus, gated by the caller with the system adapter's readiness.
var SYSTEM_EVENT_IDS = ["volumeUp", "volumeDown", "powerConnected", "powerDisconnected"]
var VOLUME_EVENT_IDS = ["volumeUp", "volumeDown"]

var ASSET_DIR = "/usr/share/sounds/freedesktop/stereo/"
var PACK_ASSET_DIR = "assets/packs/"

// The plugin's original local cue asset. ChimeController resolves relative
// catalog paths through Qt.resolvedUrl (decoded file URL) so playback never
// depends on the host shell's working directory. Freedesktop entries are
// absolute paths and need no resolution.
var NOTIFICATION_ASSET = "assets/agent-needs-input.wav"

// The selectable sound catalog (issue #7): every cue a user can assign to
// an event, each with a stable id (the serialized settings value) and the
// path pw-play receives. Theme entries are the distinct audio files of the
// installed sound-theme-freedesktop package. Symlink aliases of the theme
// (power-plug.oga, power-unplug.oga, dialog-error.oga, window-attention.oga,
// window-question.oga, network-connectivity-*.oga, screen-capture.oga) are
// excluded because they play byte-identical audio to their targets, and the
// channel/test tones (audio-channel-*.oga, audio-test-signal.oga) are
// excluded because they are calibration signals, not event cues. The
// agent-needs-input entry is the one local plugin asset.
//
// The special id "none" silences an event: no process is ever spawned for
// it. It is a first-class catalog entry (valid everywhere a sound id is),
// not a missing assignment — an assignment must never silently fall back
// to the event default just because the user chose silence.
var SOUND_NONE = "none"

var SOUND_CATALOG = {
  "alarm-clock-elapsed": { path: ASSET_DIR + "alarm-clock-elapsed.oga", label: "Alarm clock elapsed" },
  "agent-needs-input": { path: NOTIFICATION_ASSET, label: "Agent needs input (plugin)" },
  "audio-volume-change": { path: ASSET_DIR + "audio-volume-change.oga", label: "Volume change" },
  "bell": { path: ASSET_DIR + "bell.oga", label: "Bell" },
  "camera-shutter": { path: ASSET_DIR + "camera-shutter.oga", label: "Camera shutter" },
  "complete": { path: ASSET_DIR + "complete.oga", label: "Complete" },
  "device-added": { path: ASSET_DIR + "device-added.oga", label: "Device added" },
  "device-removed": { path: ASSET_DIR + "device-removed.oga", label: "Device removed" },
  "dialog-information": { path: ASSET_DIR + "dialog-information.oga", label: "Dialog information" },
  "dialog-warning": { path: ASSET_DIR + "dialog-warning.oga", label: "Dialog warning" },
  "message": { path: ASSET_DIR + "message.oga", label: "Message" },
  "message-new-instant": { path: ASSET_DIR + "message-new-instant.oga", label: "Message (new instant)" },
  "phone-incoming-call": { path: ASSET_DIR + "phone-incoming-call.oga", label: "Phone incoming call" },
  "phone-outgoing-busy": { path: ASSET_DIR + "phone-outgoing-busy.oga", label: "Phone outgoing busy" },
  "phone-outgoing-calling": { path: ASSET_DIR + "phone-outgoing-calling.oga", label: "Phone outgoing calling" },
  "service-login": { path: ASSET_DIR + "service-login.oga", label: "Service login" },
  "service-logout": { path: ASSET_DIR + "service-logout.oga", label: "Service logout" },
  "suspend-error": { path: ASSET_DIR + "suspend-error.oga", label: "Suspend error" },
  "trash-empty": { path: ASSET_DIR + "trash-empty.oga", label: "Trash emptied" },
  "none": { path: "", label: "None (silent)" }
}

var SOUND_IDS = [
  "alarm-clock-elapsed",
  "agent-needs-input",
  "audio-volume-change",
  "bell",
  "camera-shutter",
  "complete",
  "device-added",
  "device-removed",
  "dialog-information",
  "dialog-warning",
  "message",
  "message-new-instant",
  "phone-incoming-call",
  "phone-outgoing-busy",
  "phone-outgoing-calling",
  "service-login",
  "service-logout",
  "suspend-error",
  "trash-empty"
]

// Bundled theme packs use one cue per event. Their ids are derived from the
// stable pack id and event id, while paths follow the asset filenames.
// "system" remains the freedesktop assignment; "custom" is presentation
// state only and is never a writable pack.
var THEME_PACK_IDS = [
  "system",
  "zen-wood",
  "ceramic-drop",
  "kalimba",
  "deep-resonance",
  "sonar",
  "retro-hacker"
]
var THEME_PACK_LABELS = {
  system: "System default",
  "zen-wood": "Zen Wood",
  "ceramic-drop": "Ceramic Drop",
  kalimba: "Kalimba",
  "deep-resonance": "Deep Resonance",
  sonar: "Sonar",
  "retro-hacker": "Retro Hacker"
}
var THEME_PACK_CUSTOM = "custom"
var DEFAULT_THEME_PACK_ID = "retro-hacker"
var EVENT_ASSET_NAMES = {
  windowOpened: "window-opened",
  windowClosed: "window-closed",
  workspaceSwitched: "workspace-switched",
  notificationReceived: "notification-received",
  volumeUp: "volume-up",
  volumeDown: "volume-down",
  powerConnected: "power-connected",
  powerDisconnected: "power-disconnected"
}

for (var packIndex = 1; packIndex < THEME_PACK_IDS.length; packIndex++) {
  var packId = THEME_PACK_IDS[packIndex]
  for (var eventIndex = 0; eventIndex < EVENT_IDS.length; eventIndex++) {
    var packEvent = EVENT_IDS[eventIndex]
    var soundId = packId + ":" + packEvent
    SOUND_CATALOG[soundId] = {
      path: PACK_ASSET_DIR + packId + "/" + EVENT_ASSET_NAMES[packEvent] + ".wav",
      label: THEME_PACK_LABELS[packId] + " — " + EVENT_LABELS[packEvent]
    }
    SOUND_IDS.push(soundId)
  }
}
SOUND_IDS.push(SOUND_NONE)

// Keep the selectable System default independent from the plugin default so
// users can explicitly return to the freedesktop cues.
var SYSTEM_EVENT_SOUNDS = {
  windowOpened: "device-added",
  windowClosed: "device-removed",
  workspaceSwitched: "audio-volume-change",
  notificationReceived: "agent-needs-input",
  volumeUp: "audio-volume-change",
  volumeDown: "audio-volume-change",
  powerConnected: "device-added",
  powerDisconnected: "device-removed"
}

var EVENT_DEFAULT_SOUNDS = {}
for (var defaultEventIndex = 0; defaultEventIndex < EVENT_IDS.length; defaultEventIndex++) {
  var defaultEvent = EVENT_IDS[defaultEventIndex]
  EVENT_DEFAULT_SOUNDS[defaultEvent] = DEFAULT_THEME_PACK_ID + ":" + defaultEvent
}

var DEFAULT_SETTINGS = {
  enabled: true,
  volume: 0.35,
  desktopEnabled: false,
  notificationsEnabled: false
}

function copyEventSounds(source) {
  var sounds = {}
  for (var i = 0; i < EVENT_IDS.length; i++) {
    var eventName = EVENT_IDS[i]
    sounds[eventName] = source[eventName]
  }
  return sounds
}

// Return a fresh default assignment so callers never share mutable state.
function defaultEventSounds() {
  return copyEventSounds(EVENT_DEFAULT_SOUNDS)
}

// Return a fresh complete assignment for a selectable pack. Callers can
// replace the settings map atomically without sharing mutable pack state.
function themePackSounds(packId) {
  var id = String(packId || "")
  if (id === "system")
    return copyEventSounds(SYSTEM_EVENT_SOUNDS)
  if (THEME_PACK_IDS.indexOf(id) < 1)
    return null
  var sounds = {}
  for (var i = 0; i < EVENT_IDS.length; i++) {
    var eventName = EVENT_IDS[i]
    sounds[eventName] = id + ":" + eventName
  }
  return sounds
}

// Exact pack detection keeps per-event edits visible as "Custom". Settings
// are complete and validated before reaching the UI, but this helper remains
// strict so a partial or stale map is never mislabeled as a pack.
function themePackId(sounds) {
  if (!sounds || typeof sounds !== "object" || Array.isArray(sounds))
    return THEME_PACK_CUSTOM
  for (var i = 0; i < THEME_PACK_IDS.length; i++) {
    var id = THEME_PACK_IDS[i]
    var expected = themePackSounds(id)
    var matches = true
    for (var j = 0; j < EVENT_IDS.length; j++) {
      var eventName = EVENT_IDS[j]
      if (sounds[eventName] !== expected[eventName]) {
        matches = false
        break
      }
    }
    if (matches)
      return id
  }
  return THEME_PACK_CUSTOM
}

function isValidThemePack(packId) {
  return THEME_PACK_IDS.indexOf(String(packId || "")) !== -1
}

var SETTINGS_VERSION = 4
var V3_SETTINGS_VERSION = 3
var V2_SETTINGS_VERSION = 2
var LEGACY_SETTINGS_VERSION = 1
var VOLUME_MIN = 0
var VOLUME_MAX = 1
var COOLDOWN_MS = 250

function defaults() {
  return {
    enabled: DEFAULT_SETTINGS.enabled,
    volume: DEFAULT_SETTINGS.volume,
    desktopEnabled: DEFAULT_SETTINGS.desktopEnabled,
    notificationsEnabled: DEFAULT_SETTINGS.notificationsEnabled,
    sounds: defaultEventSounds()
  }
}

function isValidSound(soundId) {
  return SOUND_IDS.indexOf(String(soundId || "")) !== -1
}

function catalogSound(soundId) {
  return SOUND_CATALOG[String(soundId || "")] || null
}

// The playable path for an event under a settings "sounds" map. Falls back
// to the Retro Hacker plugin default when an assignment is missing or stale,
// never to silence or an arbitrary file. The explicit "none" assignment is
// silence: an empty path, never a fallback to the default.
function eventSoundPath(eventName, sounds) {
  var id = sounds ? sounds[eventName] : ""
  if (id === SOUND_NONE)
    return ""
  if (!id || !isValidSound(id))
    id = EVENT_DEFAULT_SOUNDS[eventName]
  var entry = catalogSound(id)
  return entry ? entry.path : ""
}

// The catalog id currently assigned to an event; falls back to the event's
// default id when the assignment is missing or stale. "none" is a valid
// assignment and is returned as-is.
function eventSoundId(eventName, sounds) {
  var id = sounds ? sounds[eventName] : ""
  if (id === SOUND_NONE)
    return SOUND_NONE
  return isValidSound(id) ? id : (EVENT_DEFAULT_SOUNDS[eventName] || "")
}

function isValidEvent(name) {
  return EVENT_IDS.indexOf(String(name || "")) !== -1
}

// The notification event is the only event whose cue is a local plugin
// asset; every other event is a desktop event from the freedesktop theme.
// This classification also drives event-specific cancellation in the
// controller: desktop gate changes cut only desktop cues and the
// notifications switch cuts only notification cues.
function isNotificationEvent(name) {
  return String(name || "") === "notificationReceived"
}

function isSystemEvent(name) {
  return SYSTEM_EVENT_IDS.indexOf(String(name || "")) !== -1
}

function isVolumeEvent(name) {
  return VOLUME_EVENT_IDS.indexOf(String(name || "")) !== -1
}

// Human-readable event names for UI display (issue #9): "windowOpened"
// shows as "Window Opened". The serialized ids and IPC surface stay
// camelCase; this is a presentation-only mapping with an exact entry per
// EVENT_IDS member and "" for anything else, so an unknown id can never
// leak into a label slot.
function eventLabel(name) {
  return EVENT_LABELS[String(name || "")] || ""
}

// Omarchy 4.0.3 capability-scopes third-party plugin shell access, so Chime
// cannot traverse the host's private service map. These parsers consume the
// supported persisted/IPC state surfaces and fail closed on partial,
// malformed, or unknown responses.
function parseDndState(text) {
  try {
    var parsed = JSON.parse(String(text || ""))
    if (!parsed || typeof parsed !== "object" || typeof parsed.dnd !== "boolean")
      return { valid: false, active: false }
    return { valid: true, active: parsed.dnd }
  } catch (e) {
    return { valid: false, active: false }
  }
}

function parseLockState(text) {
  var value = String(text || "").trim()
  if (value === "true")
    return { valid: true, active: true }
  if (value === "false")
    return { valid: true, active: false }
  return { valid: false, active: false }
}

function parseIdleState(text) {
  try {
    var parsed = JSON.parse(String(text || ""))
    if (!parsed || typeof parsed !== "object"
        || typeof parsed.idle !== "boolean"
        || typeof parsed.inIdleCycle !== "boolean"
        || typeof parsed.screensaverStarted !== "boolean"
        || typeof parsed.screensaverWindows !== "number"
        || !isFinite(parsed.screensaverWindows)
        || parsed.screensaverWindows < 0)
      return { valid: false, active: false }
    return {
      valid: true,
      active: parsed.idle || parsed.inIdleCycle
        || parsed.screensaverStarted || parsed.screensaverWindows > 0
    }
  } catch (e) {
    return { valid: false, active: false }
  }
}

function assetPath(eventName) {
  // Retained for callers that play without settings (none today): the
  // event's default catalog cue.
  return eventSoundPath(eventName, null)
}

// The single playback voice: one pw-play invocation. No shell, no quoting —
// every argument is its own list entry. The volume is already validated by
// the controller before it reaches this point.
function playerCommand(asset, volume) {
  return ["/usr/bin/pw-play", "--volume", String(volume), String(asset)]
}

// Strict parse of the settings file. The complete v4 schema is
// {version: 4, enabled: boolean, volume: finite number in [0, 1],
// desktopEnabled: boolean, notificationsEnabled: boolean,
// sounds: {event: soundId for all eight events, ids from SOUND_CATALOG}}.
// A file missing any key, or with any invalid field, is rejected as a
// whole, so a malformed or incomplete reload can never partially apply —
// mute in particular must survive intact. Unknown keys are ignored for
// forward compatibility.
//
// A complete v3 file is accepted and migrated: every field preserved and
// the per-event sounds map seeded from EVENT_DEFAULT_SOUNDS, which is
// audibly identical to what 0.3.0 played (power-plug.oga/power-unplug.oga
// are theme symlinks of device-added.oga/device-removed.oga). Complete v2
// and v1 files keep their existing migrations (agentInputEnabled carried
// over verbatim; v1's notifications off) and then gain the same default
// sounds map. Files with missing or invalid fields are rejected like any
// other malformed file.
function parseSoundsMap(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw))
    return null
  var out = {}
  for (var i = 0; i < EVENT_IDS.length; i++) {
    var eventName = EVENT_IDS[i]
    var id = raw[eventName]
    if (typeof id !== "string" || !isValidSound(id))
      return null
    out[eventName] = id
  }
  return out
}

// A v3 file has no sounds key: seed the per-event defaults (audibly
// identical to what 0.3.0 played). A v4 file must carry a complete valid
// sounds map; anything else rejects the whole file.
function migrateV3(parsed) {
  return {
    ok: true,
    settings: {
      enabled: parsed.enabled,
      volume: parsed.volume,
      desktopEnabled: parsed.desktopEnabled,
      notificationsEnabled: parsed.notificationsEnabled,
      sounds: defaultEventSounds()
    }
  }
}

function migrateV4(parsed) {
  var sounds = parseSoundsMap(parsed.sounds)
  if (!sounds)
    return { ok: false, error: "sounds must map every event to a known sound id" }
  return {
    ok: true,
    settings: {
      enabled: parsed.enabled,
      volume: parsed.volume,
      desktopEnabled: parsed.desktopEnabled,
      notificationsEnabled: parsed.notificationsEnabled,
      sounds: sounds
    }
  }
}

function parseSettings(text) {
  var parsed
  try {
    parsed = JSON.parse(String(text || ""))
  } catch (e) {
    return { ok: false, error: "invalid JSON" }
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    return { ok: false, error: "settings must be a JSON object" }
  if (parsed.version === undefined)
    return { ok: false, error: "settings version is required" }
  if (parsed.version === LEGACY_SETTINGS_VERSION) {
    if (typeof parsed.enabled !== "boolean")
      return { ok: false, error: "enabled must be a boolean" }
    if (typeof parsed.volume !== "number" || !isFinite(parsed.volume)
        || parsed.volume < VOLUME_MIN || parsed.volume > VOLUME_MAX)
      return { ok: false, error: "volume must be a finite number between 0 and 1" }
    if (typeof parsed.desktopEnabled !== "boolean")
      return { ok: false, error: "desktopEnabled must be a boolean" }
    return {
      ok: true,
      settings: {
        enabled: parsed.enabled,
        volume: parsed.volume,
        desktopEnabled: parsed.desktopEnabled,
        notificationsEnabled: false,
        sounds: defaultEventSounds()
      }
    }
  }
  if (parsed.version === V2_SETTINGS_VERSION) {
    if (typeof parsed.enabled !== "boolean")
      return { ok: false, error: "enabled must be a boolean" }
    if (typeof parsed.volume !== "number" || !isFinite(parsed.volume)
        || parsed.volume < VOLUME_MIN || parsed.volume > VOLUME_MAX)
      return { ok: false, error: "volume must be a finite number between 0 and 1" }
    if (typeof parsed.desktopEnabled !== "boolean")
      return { ok: false, error: "desktopEnabled must be a boolean" }
    if (typeof parsed.agentInputEnabled !== "boolean")
      return { ok: false, error: "agentInputEnabled must be a boolean" }
    return {
      ok: true,
      settings: {
        enabled: parsed.enabled,
        volume: parsed.volume,
        desktopEnabled: parsed.desktopEnabled,
        notificationsEnabled: parsed.agentInputEnabled,
        sounds: defaultEventSounds()
      }
    }
  }
  if (parsed.version !== SETTINGS_VERSION && parsed.version !== V3_SETTINGS_VERSION)
    return { ok: false, error: "unsupported settings version: " + parsed.version }
  if (typeof parsed.enabled !== "boolean")
    return { ok: false, error: "enabled must be a boolean" }
  if (typeof parsed.volume !== "number" || !isFinite(parsed.volume)
      || parsed.volume < VOLUME_MIN || parsed.volume > VOLUME_MAX)
    return { ok: false, error: "volume must be a finite number between 0 and 1" }
  if (typeof parsed.desktopEnabled !== "boolean")
    return { ok: false, error: "desktopEnabled must be a boolean" }
  if (typeof parsed.notificationsEnabled !== "boolean")
    return { ok: false, error: "notificationsEnabled must be a boolean" }
  if (parsed.version === V3_SETTINGS_VERSION)
    return migrateV3(parsed)
  return migrateV4(parsed)
}


function serializeSettings(settings) {
  var sounds = settings.sounds ? settings.sounds : defaultEventSounds()
  return JSON.stringify({
    version: SETTINGS_VERSION,
    enabled: !!settings.enabled,
    volume: settings.volume,
    desktopEnabled: !!settings.desktopEnabled,
    notificationsEnabled: !!settings.notificationsEnabled,
    sounds: sounds
  }, null, 2) + "\n"
}

// Decide the next settings state after a load attempt. A valid file is
// adopted. Invalid content preserves the current settings once a decision
// has been made (a malformed reload must not flip mute back on); before the
// first decision, safe defaults are used. The decision never implies a
// write — the malformed file is left untouched.
function decideSettings(current, result) {
  if (result.ok)
    return { settings: result.settings, source: "file", error: "" }
  if (current && current.settingsReady)
    return { settings: current.settings, source: "preserved", error: result.error }
  return { settings: defaults(), source: "defaults", error: result.error }
}

// First blocking reason for automatic desktop playback, or "" when every
// gate passes. Order matters: settings decided, master on, desktop sounds
// explicitly activated, no overlap, safe session, the caller-selected event
// adapter ready (the caller passes whichever source readiness governs the
// event kind — desktop adapter readiness for desktop events, system adapter
// readiness for system events), no held playback claim (same-tick
// overlapping requests are rejected). Automatic non-notification events
// ignore the post-exit cooldown entirely: the desktop/system source state
// machines already deduplicate non-transitions, and the controller preempts
// while a voice is running, so a rapid repeated event (e.g. a second
// workspaceSwitched arriving after the previous child exited but during the
// cooldown window) must stay eligible. Desktop-style gates never govern the
// notification cue, which keeps its own cooldown gate.
function automaticBlockedReason(state) {
  if (!state || !state.settingsReady) return "settings not ready"
  if (!state.enabled) return "muted"
  if (!state.desktopEnabled) return "desktop sounds disabled"
  if (state.overlapBlocked) return "blocked by ui-sounds"
  if (!state.safetyReady) return "not safe"
  if (!state.eventReady) return "event source not ready"
  if (state.playing) return "busy"
  return ""
}

// First blocking reason for notification automatic playback, or "" when
// every gate passes. The notification gate deliberately does NOT depend on
// desktop activation, ui-sounds overlap, or desktop adapter readiness: a
// notification is relevant even when desktop sounds are off. It still
// shares the master switch, session safety, and the single voice with
// desktop playback, and it keeps the post-exit cooldown as its own gate —
// notifications remain defended against rapid repeats, unlike automatic
// non-notification events which ignore the cooldown entirely.
function notificationBlockedReason(state) {
  if (!state || !state.settingsReady) return "settings not ready"
  if (!state.enabled) return "muted"
  if (!state.notificationsEnabled) return "notification sounds disabled"
  if (!state.safetyReady) return "not safe"
  if (!state.notificationReady) return "notification source not ready"
  if (state.cooldownActive) return "cooldown"
  if (state.playing) return "busy"
  return ""
}
