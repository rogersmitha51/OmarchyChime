.pragma library

// Pure policy and settings logic for the chime sound controller.
//
// Everything here is free of QML dependencies so it can be exercised with
// node:test + vm (see tests/controller.test.mjs). ChimeController.qml owns
// the FileView/Process lifecycle and calls into these functions for parsing,
// validation, and playback policy.

var EVENT_IDS = ["windowOpened", "windowClosed", "workspaceSwitched"]

var ASSET_DIR = "/usr/share/sounds/freedesktop/stereo/"

var ASSET_NAMES = {
  windowOpened: "device-added.oga",
  windowClosed: "device-removed.oga",
  workspaceSwitched: "audio-volume-change.oga"
}

var DEFAULT_SETTINGS = {
  enabled: true,
  volume: 0.35,
  desktopEnabled: false
}

var SETTINGS_VERSION = 1
var VOLUME_MIN = 0
var VOLUME_MAX = 1
var COOLDOWN_MS = 250

function defaults() {
  return {
    enabled: DEFAULT_SETTINGS.enabled,
    volume: DEFAULT_SETTINGS.volume,
    desktopEnabled: DEFAULT_SETTINGS.desktopEnabled
  }
}

function isValidEvent(name) {
  return EVENT_IDS.indexOf(String(name || "")) !== -1
}

function assetPath(eventName) {
  var name = ASSET_NAMES[eventName]
  return name ? ASSET_DIR + name : ""
}

// The single playback voice: one pw-play invocation. No shell, no quoting —
// every argument is its own list entry. The volume is already validated by
// the controller before it reaches this point.
function playerCommand(asset, volume) {
  return ["/usr/bin/pw-play", "--volume", String(volume), String(asset)]
}

// Strict parse of the settings file. The complete schema is
// {version: 1, enabled: boolean, volume: finite number in [0, 1],
// desktopEnabled: boolean}. A file missing any key, or with any invalid
// field, is rejected as a whole, so a malformed or incomplete reload can
// never partially apply — mute in particular must survive intact. Unknown
// keys are ignored for forward compatibility.
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
  if (parsed.version !== SETTINGS_VERSION)
    return { ok: false, error: "unsupported settings version: " + parsed.version }
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
      desktopEnabled: parsed.desktopEnabled
    }
  }
}

function serializeSettings(settings) {
  return JSON.stringify({
    version: SETTINGS_VERSION,
    enabled: !!settings.enabled,
    volume: settings.volume,
    desktopEnabled: !!settings.desktopEnabled
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

// First blocking reason for automatic playback, or "" when every gate
// passes. Order matters: settings decided, master on, desktop sounds
// explicitly activated, no overlap, safe session, desktop adapter ready,
// cooldown elapsed, no held playback claim (same-tick overlapping requests
// are rejected).
function automaticBlockedReason(state) {
  if (!state || !state.settingsReady) return "settings not ready"
  if (!state.enabled) return "muted"
  if (!state.desktopEnabled) return "desktop sounds disabled"
  if (state.overlapBlocked) return "blocked by ui-sounds"
  if (!state.safetyReady) return "not safe"
  if (!state.desktopReady) return "desktop not ready"
  if (state.cooldownActive) return "cooldown"
  if (state.playing) return "busy"
  return ""
}
