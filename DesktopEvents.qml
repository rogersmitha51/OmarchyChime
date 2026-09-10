// Desktop event adapter: turns Hyprland window/workspace activity into the
// three chime events (windowOpened, windowClosed, workspaceSwitched).
//
// This component is deliberately dumb about audio: it tracks and reports
// desktop activity even while the chime's own audio is muted, disabled, or
// overlap-blocked, so the controller can decide what to play. `active`
// means the host/compositor monitoring is safe — NOT mute, desktopEnabled,
// or overlap state.
//
// Readiness is a settling model. After startup, safe reactivation, or any
// monitor/screen topology change, the adapter waits out a grace window
// without tracking events, then takes a silent baseline snapshot of the
// live models (which includes anything that arrived during grace) and only
// then enables event output. `ready` is false for the whole settling
// window, including the moment of the final seed.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import "DesktopLogic.js" as DesktopLogic

Item {
  id: root

  // Safe host/compositor monitoring readiness. The host (Service.qml) sets
  // this true only once the session is unlocked, non-idle, on a real screen,
  // and past startup grace; it flips false on lock/idle/screen loss. While
  // false the adapter drops its baseline and suppresses events; on
  // reactivation it re-arms the settling window and re-baselines silently,
  // so nothing that happened while inactive sounds.
  property bool active: false

  readonly property bool ready: root.active && DesktopLogic.hasRealScreen(Quickshell.screens || []) && root._hyprlandPresent && root._seeded && root._settled

  // Emitted for exactly the three real desktop events. Never emitted for
  // seeds, ignored surfaces, duplicate reports, or unknown closes.
  signal eventOccurred(string eventName)

  // Transient state machine. Deliberately not persisted: a QML reload must
  // start from a fresh baseline, never from stale pre-reload windows.
  property var _state: DesktopLogic.newState()

  property bool _hyprlandPresent: false
  property bool _seeded: false
  property bool _settled: false

  // The Hyprland singleton has no `connected` property; presence is derived
  // from the IPC models being populated. A compositor restart tears the
  // models down (empty values) and repopulates them, which is exactly the
  // signal we need to reseed.
  readonly property bool _modelsPresent: {
    var monitors = Hyprland.monitors
    var toplevels = Hyprland.toplevels
    return !!(monitors && monitors.values && monitors.values.length > 0 && toplevels && toplevels.values)
  }

  // Monitor topology fingerprint: the set of monitor names. A change means
  // monitors were added or removed, so per-monitor baselines and the
  // focused-monitor pointer are stale. Workspace ids are deliberately
  // excluded: an ordinary workspace switch must not invalidate the baseline
  // (that would swallow the very event we want to hear).
  readonly property string _monitorFingerprint: {
    var monitors = Hyprland.monitors
    if (!monitors || !monitors.values)
      return ""
    var parts = []
    var values = monitors.values
    for (var i = 0; i < values.length; i++) {
      var monitor = values[i]
      if (!monitor)
        continue
      var name = String(monitor.name || "").trim().toLowerCase()
      if (name)
        parts.push(name)
    }
    parts.sort()
    return parts.join("|")
  }

  // Screen topology fingerprint: real screen names and geometry. A change
  // invalidates the baseline even when the monitor list stays nonempty
  // (e.g. an output is replaced by another with the same monitor name).
  readonly property string _screenFingerprint: {
    var screens = Quickshell.screens || []
    var parts = []
    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (!screen)
        continue
      var name = String(screen.name || "").trim()
      if (!name || name.toUpperCase() === "FALLBACK")
        continue
      parts.push(name + "@" + screen.x + "," + screen.y + " " + screen.width + "x" + screen.height)
    }
    parts.sort()
    return parts.join("|")
  }

  function _dropBaseline() {
    root._state = DesktopLogic.newState()
    root._seeded = false
    root._settled = false
    settleTimer.stop()
  }

  function _armSettling() {
    if (!root.active)
      return
    settleTimer.stop()
    settleTimer.restart()
  }

  // Rebuild the baseline from scratch: drop the transient state and wait
  // out a fresh settling window before the silent final seed.
  function _resetBaseline() {
    root._dropBaseline()
    root._armSettling()
  }

  // Silent baseline snapshot taken at the end of settling, before event
  // output is enabled. Replaces the whole window/monitor baseline with the
  // live models, so anything that arrived during the grace window is
  // captured and stays silent. Never emits.
  function _finalSeed() {
    if (!root._modelsPresent)
      return false
    DesktopLogic.seedWindows(root._state, Hyprland.toplevels.values)
    DesktopLogic.seedMonitors(root._state, Hyprland.monitors.values)
    root._seeded = true
    return true
  }

  function _refreshPresence() {
    var present = root._modelsPresent
    if (present === root._hyprlandPresent)
      return
    root._hyprlandPresent = present
    if (present) {
      // Models (re)appeared: startup or compositor restart. Rebuild the
      // baseline after a fresh settling window.
      root._resetBaseline()
    } else {
      // Models gone: compositor or topology lost. Drop the baseline so a
      // later repopulation is a fresh start, not a transition.
      root._dropBaseline()
    }
  }

  function _isTopologyEvent(name) {
    return name === "monitoradded" || name === "monitoraddedv2" || name === "monitorremoved" || name === "monitorremovedv2" || name === "moveworkspace" || name === "moveworkspacev2" || name === "configreloaded"
  }

  function _handleEvent(event) {
    if (!root.active)
      return
    var name = String(event && event.name ? event.name : "")
    if (root._isTopologyEvent(name)) {
      // Monitor/workspace topology changed: per-monitor baselines and the
      // focused-monitor pointer are stale. Rebuild silently.
      root._resetBaseline()
      return
    }
    if (!root._settled)
      return
    var eventName = DesktopLogic.handleEvent(root._state, event)
    if (eventName)
      root.eventOccurred(eventName)
  }

  function status() {
    return {
      active: root.active,
      ready: root.ready,
      hyprlandPresent: root._hyprlandPresent,
      seeded: root._seeded,
      startupGraceComplete: root._settled,
      listening: root._settled && root.active,
      windows: DesktopLogic.windowCount(root._state),
      ignored: DesktopLogic.ignoredCount(root._state),
      monitors: DesktopLogic.monitorCount(root._state),
      events: DesktopLogic.EVENT_IDS
    }
  }

  onActiveChanged: {
    if (root.active) {
      // Safe reactivation: re-arm the settling window and rebuild the
      // baseline so nothing that happened while inactive sounds.
      root._resetBaseline()
    } else {
      // Deactivated: stop tracking and drop the transient baseline.
      root._dropBaseline()
    }
  }

  on_ModelsPresentChanged: root._refreshPresence()

  on_MonitorFingerprintChanged: {
    // Only react to real topology changes between non-empty states. The
    // empty fingerprint (no monitors yet) and the empty->populated startup
    // transition are handled by _modelsPresent.
    if (root.active && root._monitorFingerprint !== "")
      root._resetBaseline()
  }

  on_ScreenFingerprintChanged: {
    if (root.active && root._screenFingerprint !== "")
      root._resetBaseline()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      root._handleEvent(event)
    }
  }

  Timer {
    id: settleTimer
    interval: 1500
    repeat: false
    onTriggered: {
      if (root._finalSeed())
        root._settled = true
      // Models not present yet: stay un-settled. The next model population
      // re-arms settling via _refreshPresence.
    }
  }

  Component.onCompleted: {
    root._refreshPresence()
    if (root.active)
      root._armSettling()
  }
}
