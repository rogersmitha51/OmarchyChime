.pragma library

// Pure policy and settings logic for the chime sound controller.
//
// Everything here is free of QML dependencies so it can be exercised with
// node:test + vm (see tests/controller.test.mjs). ChimeController.qml owns
// the FileView/Process lifecycle and calls into these functions for parsing,
// validation, and playback policy.

var EVENT_IDS = ["windowOpened", "windowClosed", "workspaceSwitched", "notificationReceived", "volumeUp", "volumeDown", "powerConnected", "powerDisconnected"]

// The four system events: volume and power-state cues driven by the session
// bus, gated by the caller with the system adapter's readiness.
var SYSTEM_EVENT_IDS = ["volumeUp", "volumeDown", "powerConnected", "powerDisconnected"]

var ASSET_DIR = "/usr/share/sounds/freedesktop/stereo/"

// The notification cue is a local plugin asset; ChimeController resolves the
// relative path through Qt.resolvedUrl (decoded file URL) so playback never
// depends on the host shell's working directory. Desktop and system events
// keep the stock freedesktop sound theme.
var NOTIFICATION_ASSET = "assets/agent-needs-input.wav"

var ASSET_NAMES = {
  windowOpened: ASSET_DIR + "device-added.oga",
  windowClosed: ASSET_DIR + "device-removed.oga",
  workspaceSwitched: ASSET_DIR + "audio-volume-change.oga",
  volumeUp: ASSET_DIR + "audio-volume-change.oga",
  volumeDown: ASSET_DIR + "audio-volume-change.oga",
  powerConnected: ASSET_DIR + "power-plug.oga",
  powerDisconnected: ASSET_DIR + "power-unplug.oga",
  notificationReceived: NOTIFICATION_ASSET
}

var DEFAULT_SETTINGS = {
  enabled: true,
  volume: 0.35,
  desktopEnabled: false,
  notificationsEnabled: false
}

var SETTINGS_VERSION = 3
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
    notificationsEnabled: DEFAULT_SETTINGS.notificationsEnabled
  }
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

function assetPath(eventName) {
  var name = ASSET_NAMES[eventName]
  return name ? name : ""
}

// The single playback voice: one pw-play invocation. No shell, no quoting —
// every argument is its own list entry. The volume is already validated by
// the controller before it reaches this point.
function playerCommand(asset, volume) {
  return ["/usr/bin/pw-play", "--volume", String(volume), String(asset)]
}

// Strict parse of the settings file. The complete v3 schema is
// {version: 3, enabled: boolean, volume: finite number in [0, 1],
// desktopEnabled: boolean, notificationsEnabled: boolean}. A file missing
// any key, or with any invalid field, is rejected as a whole, so a malformed
// or incomplete reload can never partially apply — mute in particular must
// survive intact. Unknown keys are ignored for forward compatibility.
//
// A complete v2 file ({version: 2, enabled, volume, desktopEnabled,
// agentInputEnabled}) is accepted and migrated with the old switch carried
// over verbatim into notificationsEnabled. A complete v1 file ({version: 1,
// enabled, volume, desktopEnabled}) is accepted and migrated with the new
// notifications switch off, preserving every existing field. v1/v2 files
// with missing or invalid fields are rejected like any other malformed file.
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
        notificationsEnabled: false
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
        notificationsEnabled: parsed.agentInputEnabled
      }
    }
  }
  if (parsed.version !== SETTINGS_VERSION)
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

  return {
    ok: true,
    settings: {
      enabled: parsed.enabled,
      volume: parsed.volume,
      desktopEnabled: parsed.desktopEnabled,
      notificationsEnabled: parsed.notificationsEnabled
    }
  }
}

function serializeSettings(settings) {
  return JSON.stringify({
    version: SETTINGS_VERSION,
    enabled: !!settings.enabled,
    volume: settings.volume,
    desktopEnabled: !!settings.desktopEnabled,
    notificationsEnabled: !!settings.notificationsEnabled
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
