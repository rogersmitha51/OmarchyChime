.pragma library

// Pure state machine for the system event adapter (SystemEvents.qml). No
// QML, no timers, no host access: everything here is deterministic over the
// readings it is fed, so it can be regression-tested under plain node.
//
// The adapter owns two fully independent sources:
//   - volume: the current default audio sink's average volume. The baseline
//     is bound to a sink identity (String(id)); a sink identity change
//     silently clears the volume baseline so the new sink's volume is never
//     compared against the old sink's.
//   - power: the UPower on-battery boolean. It has no identity and only
//     requires a strict boolean.
// Each source emits transitions only after its own silent baseline, so
// either source may function while the other is absent.

// The event IDs SystemEvents.eventOccurred emits. This is the adapter's
// public contract with the audio controller.
var EVENT_IDS = ["volumeUp", "volumeDown", "powerConnected", "powerDisconnected"]

function newState() {
  return {
    // Identity of the current default audio sink. "" means there is no
    // sink, so no volume baseline can exist.
    sinkId: "",
    // Last seeded volume of the current sink. NaN marks "no baseline":
    // PipeWire volumes are floats but the pure layer only ever seeds
    // finite numbers, so NaN can never be confused with a real volume.
    volume: NaN,
    volumeSeeded: false,
    // Last seeded on-battery reading. `powerSeeded` marks "no baseline".
    power: false,
    powerSeeded: false
  }
}

// Finite-number validation for volume readings. Rejects NaN, infinities,
// non-numbers, and anything coercible (null, strings) — a reading must be
// a real number to count. Out-of-range-but-finite values (e.g. > 1.0,
// where PipeWire allows 150 %) are still real readings.
function isFiniteNumber(value) {
  return typeof value === "number" && isFinite(value)
}

// Sink ids are compared as strings: PipeWire reuses ids across iface
// recreations, and quickshell recreates the PwNodeIface wrappers, so object
// identity is meaningless. Null/undefined mean "no sink" ("").
function normalizeSinkId(sinkId) {
  return sinkId === undefined || sinkId === null ? "" : String(sinkId)
}

function isVolumeSeeded(state) {
  return !!(state && state.volumeSeeded)
}

function isPowerSeeded(state) {
  return !!(state && state.powerSeeded)
}

function currentSinkId(state) {
  return state ? String(state.sinkId) : ""
}

function currentVolume(state) {
  return state && state.volumeSeeded ? state.volume : null
}

function currentPower(state) {
  return state && state.powerSeeded ? state.power : null
}

// Silent baseline: adopt the current sink's volume as the comparison
// baseline for that sink. Never emits; rejected unless the volume is a
// finite number.
function seedVolume(state, sinkId, volume) {
  if (!isFiniteNumber(volume))
    return false
  state.sinkId = normalizeSinkId(sinkId)
  state.volume = volume
  state.volumeSeeded = true
  return true
}

// Silent baseline: adopt the current AC/battery reading. Never emits;
// rejected unless the reading is a strict boolean.
function seedPower(state, onBattery) {
  if (typeof onBattery !== "boolean")
    return false
  state.power = onBattery
  state.powerSeeded = true
  return true
}

// The sink identity changed (including to or from none): the established
// volume baseline belongs to the previous sink, so it is dropped and the
// next valid reading attributed to the new sink becomes a silent fresh
// baseline. Returns true when the identity actually changed; a repeated
// identity is a no-op, so spurious defaultAudioSinkChanged signals cannot
// clear a live baseline. The independent power baseline is never touched.
function resetSink(state, sinkId) {
  var id = normalizeSinkId(sinkId)
  if (id === state.sinkId)
    return false
  state.sinkId = id
  state.volume = NaN
  state.volumeSeeded = false
  return true
}

// Judge a volume reading against the baseline. Returns the emitted event
// name ("volumeUp" or "volumeDown"), or "" when the reading is silent:
//   - an invalid (non-finite) value — never seeds;
//   - an unattributable reading (empty sink id) — never seeds;
//   - the first valid reading — a silent baseline (the baseline sink id is
//     recorded from it);
//   - a stale reading attributed to a sink that is not the baseline sink —
//     never seeds, so a late old-sink reading cannot poison the current
//     sink's baseline;
//   - a repeat of the latest volume.
// Valid readings from the current sink always become the new baseline as
// they are judged, so the next reading compares against the latest volume.
function handleVolumeChange(state, sinkId, volume) {
  if (!isFiniteNumber(volume))
    return ""
  var id = normalizeSinkId(sinkId)
  if (!state.volumeSeeded) {
    if (!id)
      return ""
    state.sinkId = id
    state.volume = volume
    state.volumeSeeded = true
    return ""
  }
  if (!id || id !== state.sinkId)
    return ""
  var previous = state.volume
  if (volume === previous)
    return ""
  state.volume = volume
  return volume > previous ? "volumeUp" : "volumeDown"
}

// Judge an AC/battery reading against the baseline. Returns the emitted
// event name ("powerConnected" or "powerDisconnected"), or "" when silent:
// an invalid (non-boolean) value — never seeds; the first valid reading — a
// silent baseline; a repeat of the latest reading. Running on battery
// (true) means the AC supply was disconnected; running on AC (false) means
// it was connected.
function handlePowerChange(state, onBattery) {
  if (typeof onBattery !== "boolean")
    return ""
  if (!state.powerSeeded) {
    state.power = onBattery
    state.powerSeeded = true
    return ""
  }
  if (onBattery === state.power)
    return ""
  state.power = onBattery
  return onBattery ? "powerDisconnected" : "powerConnected"
}
