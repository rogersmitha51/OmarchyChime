// System event adapter: turns audio-volume and AC/battery state changes
// into the four chime events (volumeUp, volumeDown, powerConnected,
// powerDisconnected).
//
// This component is deliberately dumb about audio: it tracks and reports
// system state even while the chime's own audio is muted, disabled, or
// overlap-blocked, so the controller can decide what to play. `active`
// means the host/session monitoring is safe — NOT mute, desktopEnabled,
// or overlap state.
//
// The two sources are fully independent: the volume source (PipeWire)
// functions without UPower, and the power source (UPower) functions without
// PipeWire. A missing backend keeps that source unready; readiness is the
// OR of the seeded sources, so losing one backend never disables the other
// (PipeWire.ready gates the volume source, UPower presence gates the power
// source).
//
// Readiness is a settling model. Nothing emits until a source has taken its
// silent baseline of the live state (which includes anything that settled
// before activation), and after deactivation both baselines are dropped so
// nothing that happened while inactive sounds on re-activation. No clock is
// involved: the pipewire `ready` flag and per-node `ready` flags already
// settle quickshell's initial sync, and the volume baseline is only ever
// taken from a fully bound default sink. A sink swap briefly nulls
// defaultAudioSink; the swap is detected as a sink identity change and
// reseeds the volume baseline silently for the new sink, so the old sink's
// volume is never compared against the new sink's and a startup/reload
// burst is impossible. Mute changes never fire the volume signal, so they
// can never be mistaken for volume events.

import QtQuick
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import "SystemLogic.js" as SystemLogic

Item {
  id: root

  // Safe host/session monitoring readiness. The host (Service.qml) sets
  // this true only once the session is unlocked, non-idle, on a real
  // screen, and past startup grace; it flips false on lock/idle/screen
  // loss. While false the adapter drops its baselines and suppresses
  // events; on reactivation it re-baselines silently, so nothing that
  // happened while inactive sounds.
  property bool active: false

  readonly property bool ready: root.active && (root.volumeReady || root.powerReady)

  // Independent source readiness. Each becomes true once its silent
  // baseline is established over a live, ready backend: the default sink
  // fully bound and read (volume), or a strict on-battery reading from
  // UPower (power). A missing backend keeps its source unready.
  property bool volumeReady: false
  property bool powerReady: false

  // Emitted for exactly the four real system events. Never emitted for
  // seeds, baseline comparisons, invalid readings, stale-sink readings, or
  // repeated readings.
  signal eventOccurred(string eventName)

  // Transient state. Deliberately not persisted: a QML reload must start
  // from a fresh baseline, never from stale pre-reload state.
  property var _state: SystemLogic.newState()

  // PwObjectTracker keeps the volume reading alive: pipewire only streams
  // volume/mute params to quickshell while the node is bound, so when the
  // default sink object is unbound all of PwNodeAudio's properties (and the
  // volumesChanged signal) stop flowing. objects is an array binding and
  // may contain nulls, which PwObjectTracker tolerates.
  //
  // `ObjectsRequireNonNull` must be disabled for the array binding: the
  // binding itself cannot guarantee a non-null result (defaultAudioSink
  // is null when there is no sink), so enforcing it would turn every sink
  // swap into a binding-invalidation error.
  PwObjectTracker {
    id: sinkTracker
    // eslint-disable-next-line qmllint/objects-require-non-null
    objects: [Pipewire.defaultAudioSink]
  }

  readonly property string _sinkId: {
    var node = Pipewire.defaultAudioSink
    return node ? SystemLogic.normalizeSinkId(node.id) : ""
  }

  // Is the volume source usable right now? Pipewire.ready confirms the
  // initial sync of the node registry completed; the node itself must be
  // fully bound (ready) before its volume means anything. defaultAudioSink
  // is null before ready and briefly during a sink swap. The audio iface of
  // a non-audio node (null) also disqualifies the source. This is a plain
  // boolean property so binding dependencies are tracked exactly: Pipewire
  // ready, the default sink pointer, and the node's ready flag.
  readonly property bool _volumeUsable: {
    if (!root.active || !Pipewire.ready)
      return false
    var node = Pipewire.defaultAudioSink
    if (!node || !node.ready || !node.audio)
      return false
    var volume = node.audio.volume
    if (!SystemLogic.isFiniteNumber(volume))
      return false
    return true
  }

  // Is the power source usable right now? UPower may be entirely absent
  // (no daemon); quickshell's UPower singleton exists either way. The
  // display device must have finished its initial GetAll (ready) for its
  // on-battery state to mean anything. OnBattery is D-Bus-bound and updates
  // automatically on AC/battery changes — nothing is polled or mutated.
  readonly property bool _powerUsable: {
    if (!root.active)
      return false
    var display = UPower.displayDevice
    if (!display || !display.ready)
      return false
    return typeof UPower.onBattery === "boolean"
  }

  function status() {
    return {
      active: root.active,
      ready: root.ready,
      volumeReady: root.volumeReady,
      powerReady: root.powerReady,
      sinkId: root._sinkId,
      volume: SystemLogic.currentVolume(root._state),
      power: SystemLogic.currentPower(root._state),
      volumeSourceUsable: root._volumeUsable,
      powerSourceUsable: root._powerUsable,
      pipewireReady: Pipewire.ready,
      events: SystemLogic.EVENT_IDS
    }
  }

  // Silent reseed of a source baseline. Never emits. The node must be
  // fully bound and readable: before the initial sync finishes the bound
  // audio iface's volumes are empty (averageVolume 0.0), and seeding that
  // would make the first real volume read look like a fall. Quickshell
  // flips node.ready false before clearing volume params on unbind, so the
  // ready check also rejects post-unbind cleared reads.
  function _reseedVolume() {
    var node = Pipewire.defaultAudioSink
    if (!node || !node.ready || !node.audio)
      return
    if (!root._volumeUsable)
      return
    if (SystemLogic.seedVolume(root._state, node.id, node.audio.volume))
      root.volumeReady = true
  }

  function _reseedPower() {
    var display = UPower.displayDevice
    if (!display || !display.ready)
      return
    if (SystemLogic.seedPower(root._state, UPower.onBattery))
      root.powerReady = true
  }

  // Drop both baselines and source readiness. Used on deactivation and
  // before a silent reseed, so a stale baseline can never be compared
  // against post-reactivation state.
  function _dropBaselines() {
    root._state = SystemLogic.newState()
    root.volumeReady = false
    root.powerReady = false
  }

  function _handleVolume(sinkId, volume) {
    if (!root.active)
      return
    var eventName = SystemLogic.handleVolumeChange(root._state, sinkId, volume)
    if (eventName)
      root.eventOccurred(eventName)
  }

  function _handlePower(onBattery) {
    if (!root.active)
      return
    var eventName = SystemLogic.handlePowerChange(root._state, onBattery)
    if (eventName)
      root.eventOccurred(eventName)
  }

  onActiveChanged: {
    if (root.active) {
      // Safe reactivation: re-baseline both sources silently so nothing
      // that happened while inactive sounds.
      root._dropBaselines()
      root._reseedVolume()
      root._reseedPower()
    } else {
      // Deactivated: stop tracking and drop the transient baselines.
      root._dropBaselines()
    }
  }

  // The sink identity changed. Drop the old sink's volume baseline and, if
  // the new sink is usable, reseed it silently — never emit. The identity
  // comparison handles swaps, the brief null gap, and initial population;
  // resetSink is a no-op for a repeated identity, so spurious
  // defaultAudioSinkChanged signals cannot clear a live baseline. The power
  // baseline is untouched.
  on_SinkIdChanged: {
    if (!root.active)
      return
    if (SystemLogic.resetSink(root._state, root._sinkId))
      root.volumeReady = false
    root._reseedVolume()
  }

  Connections {
    target: Pipewire
    function onDefaultAudioSinkChanged() {
      // The sink pointer itself changed: identity is recomputed by the
      // _sinkId binding; the handler on_SinkIdChanged does the reseed.
    }
    function onReadyChanged() {
      if (!root.active)
        return
      if (Pipewire.ready) {
        // Initial sync completed (or reconnected): establish the volume
        // baseline over the settled graph, silently.
        root._reseedVolume()
      } else {
        // Pipewire is gone: its nodes are tearing down. Drop the volume
        // baseline; the sink identity change handler will also fire as the
        // default sink disappears. Power is independent and survives.
        root.volumeReady = false
      }
    }
  }

  // The volume source became usable: the default sink (or an existing sink)
  // reached a fully bound, readable state after PipeWire registry readiness.
  // Establish the volume baseline over the settled graph, silently — a node
  // can finish its initial sync after Pipewire.ready, and without this the
  // source would stay unready until the next sink change.
  on_VolumeUsableChanged: {
    if (!root.active)
      return
    if (root._volumeUsable)
      root._reseedVolume()
  }

  // Volume changes arrive exclusively through the current default sink's
  // PwNodeAudio.volumesChanged. The reading is attributed to that sink's
  // identity, so a stale event from a previous sink can never be mistaken
  // for the current sink's volume. Mute changes fire mutedChanged, never
  // this signal, so they can never be misread as volume events.
  // PwNodeAudio.volumesChanged also fires on unbind with cleared volumes
  // (0.0); node.ready flips false before that signal is emitted, so the
  // ready guard in onVolumesChanged rejects the clear before it can sound.
  onVolumeReadyChanged: {
    var node = Pipewire.defaultAudioSink
    volumeConnections.target = root.volumeReady && node && node.audio ? node.audio : null
  }

  // target is null during the initial sync, while the default sink is
  // unbound (a sink swap), or for a non-audio node; suppress the
  // "no signal of target matches" warning those null/shape transitions
  // would otherwise emit, while the real PwNodeAudio volumesChanged
  // signal stays connected whenever target is a live audio iface.
  Connections {
    id: volumeConnections
    ignoreUnknownSignals: true
    function onVolumesChanged() {
      if (!root.active || !root.volumeReady)
        return
      var node = Pipewire.defaultAudioSink
      // The ready guard rejects the unbind-clear burst: quickshell sets
      // node.ready false and then emits volumesChanged with cleared
      // volumes. A volume event can only have come from the current sink:
      // the only PwNodeAudio we subscribe to is the current default sink's,
      // so a stale sink cannot emit into this adapter at all.
      if (!node || !node.ready || !node.audio || !root.volumeReady)
        return
      var volume = node.audio.volume
      if (!SystemLogic.isFiniteNumber(volume))
        return
      root._handleVolume(node.id, volume)
    }
  }

  // The power source became usable: the display device finished its initial
  // reading while still reporting a strict boolean. Reseed silently so the
  // first real transition still emits; the display device may be unready at
  // startup, and onBatteryChanged arrives from the UPower singleton only
  // after that initial GetAll settled.
  on_PowerUsableChanged: {
    if (!root.active)
      return
    if (root._powerUsable)
      root._reseedPower()
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      if (!root.active)
        return
      if (root._powerUsable)
        root._handlePower(UPower.onBattery)
      else
        // Not usable yet (display device still initializing): adopt the
        // reading as a silent baseline instead of judging it, so the first
        // real transition after readiness still emits.
        root._reseedPower()
    }
  }

  Connections {
    target: UPower.displayDevice
    function onReadyChanged() {
      if (!root.active)
        return
      if (root._powerUsable)
        root._reseedPower()
    }
  }

  Component.onCompleted: {
    if (root.active) {
      root._reseedVolume()
      root._reseedPower()
    }
  }
}
