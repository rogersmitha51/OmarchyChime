.pragma library

// Pure state machine for the desktop event adapter. No QML, no timers, no
// host access: everything here is deterministic over the events and model
// snapshots it is fed, so it can be regression-tested under plain node.

// The event IDs DesktopEvents.eventOccurred emits. This is the adapter's
// public contract with the audio controller.
var EVENT_IDS = ["windowOpened", "windowClosed", "workspaceSwitched"]

// Window classes that belong to the shell, lock, screensaver, or picker
// surfaces. Their open/close cycles are not desktop events: opening one is
// silent, and its close is remembered so it stays silent too.
var IGNORE_CLASSES = {
  "hyprland-preview-share-picker": true,
  "xdph-picker": true,
  "org.omarchy.screensaver": true,
  "org.omarchy.lock": true,
  "omarchy-lock": true,
  "omarchy-shell": true,
  "quickshell": true,
  "gtk-layer-shell": true,
  "hyprlock": true,
  "swaylock": true
}

// Bounded FIFO for ignored-class windows that never report a close (a picker
// that crashed, a lock surface torn down by the compositor). Prevents an
// unbounded leak; eviction is deterministic, no clock involved.
var MAX_IGNORED_WINDOWS = 128

function newState() {
  return {
    windows: {},        // address -> { klass } — real windows in the current baseline
    ignored: {},        // address -> { klass } — ignored-class windows, remembered for their close
    ignoredOrder: [],   // FIFO of ignored addresses for bounded eviction
    monitors: {},       // monitorName -> active workspace id
    focusedMonitor: ""  // name of the currently focused monitor
  }
}

// Hyprland window addresses are hex; the raw IPC reports them with a 0x
// prefix while the model's `address` property may omit it. Normalize both to
// the same bare hex form so a seeded window and its raw close match.
function normalizedAddress(address) {
  var value = String(address || "").trim().toLowerCase()
  if (value.indexOf("0x") === 0)
    value = value.slice(2)
  return value
}

function normalizedClass(klass) {
  return String(klass || "").trim().toLowerCase()
}

function isIgnoredClass(klass) {
  return IGNORE_CLASSES[normalizedClass(klass)] === true
}

function eventParts(event, count) {
  try {
    if (event && event.parse)
      return event.parse(count)
  } catch (error) {
  }
  return String(event && event.data ? event.data : "").split(",")
}

function rememberIgnored(ignored, order, address, klass) {
  if (ignored[address])
    return
  ignored[address] = { klass: klass }
  order.push(address)
  while (order.length > MAX_IGNORED_WINDOWS) {
    var stale = order.shift()
    delete ignored[stale]
  }
}

function forgetIgnored(state, address) {
  if (!state.ignored[address])
    return false
  delete state.ignored[address]
  var index = state.ignoredOrder.indexOf(address)
  if (index >= 0)
    state.ignoredOrder.splice(index, 1)
  return true
}

// openwindow data: ADDRESS,WORKSPACE,CLASS,TITLE
function handleOpenWindow(state, event) {
  var parts = eventParts(event, 4)
  var address = normalizedAddress(parts[0])
  if (!address)
    return ""
  // Duplicate report of a window we already track: not a new event.
  if (state.windows[address] || state.ignored[address])
    return ""
  var klass = normalizedClass(parts[2])
  if (isIgnoredClass(klass)) {
    rememberIgnored(state.ignored, state.ignoredOrder, address, klass)
    return ""
  }
  state.windows[address] = { klass: klass }
  return "windowOpened"
}

// closewindow data: ADDRESS
function handleCloseWindow(state, event) {
  var parts = eventParts(event, 1)
  var address = normalizedAddress(parts[0])
  if (!address)
    return ""
  if (forgetIgnored(state, address))
    return ""
  if (state.windows[address]) {
    delete state.windows[address]
    return "windowClosed"
  }
  // Unknown close: a window that was never seeded or opened while listening.
  // Not a tracked event.
  return ""
}

// workspacev2 data: WORKSPACEID,WORKSPACENAME. The event names no monitor;
// it applies to the remembered focused monitor. Unknown focus is silent.
function handleWorkspaceV2(state, event) {
  var parts = eventParts(event, 2)
  var workspaceId = String(parts[0] || "").trim()
  if (!workspaceId)
    return ""
  var monitor = state.focusedMonitor
  if (!monitor)
    return ""
  var previous = state.monitors[monitor]
  state.monitors[monitor] = workspaceId
  // First sighting of this monitor's workspace is a silent baseline, not a
  // transition; a repeated report of the same workspace is silent too.
  if (previous === undefined || previous === workspaceId)
    return ""
  return "workspaceSwitched"
}

// focusedmonv2 data: MONNAME,WORKSPACEID. Moves the focused-monitor pointer
// only; it never emits and never touches per-monitor baselines, so a later
// workspacev2 for that monitor is still judged against its own baseline.
function handleFocusedMonV2(state, event) {
  var parts = eventParts(event, 2)
  var monitor = String(parts[0] || "").trim().toLowerCase()
  if (!monitor)
    return ""
  state.focusedMonitor = monitor
  return ""
}

function handleEvent(state, event) {
  var name = String(event && event.name ? event.name : "")
  if (name === "openwindow")
    return handleOpenWindow(state, event)
  if (name === "closewindow")
    return handleCloseWindow(state, event)
  if (name === "workspacev2")
    return handleWorkspaceV2(state, event)
  if (name === "focusedmonv2")
    return handleFocusedMonV2(state, event)
  return ""
}

// Silent baseline: replace the window baseline with the current toplevels so
// pre-startup windows do not sound on open, their closes are recognized as
// real events, and ignored-class surfaces stay silent. Never emits.
function seedWindows(state, toplevels) {
  var list = toplevels || []
  var windows = {}
  var ignored = {}
  var ignoredOrder = []
  for (var i = 0; i < list.length; i++) {
    var toplevel = list[i]
    if (!toplevel)
      continue
    var address = normalizedAddress(toplevel.address)
    if (!address)
      continue
    // The installed HyprlandToplevel has no `class` property; the class is
    // only available through the raw IPC snapshot.
    var klass = normalizedClass(toplevel.class
      || (toplevel.lastIpcObject && toplevel.lastIpcObject.class))
    if (isIgnoredClass(klass))
      rememberIgnored(ignored, ignoredOrder, address, klass)
    else
      windows[address] = { klass: klass }
  }
  state.windows = windows
  state.ignored = ignored
  state.ignoredOrder = ignoredOrder
}

// Silent baseline: replace the monitor baseline with the current monitors,
// recording each monitor's active workspace and the focused monitor. Never
// emits.
function seedMonitors(state, monitors) {
  var list = monitors || []
  var byName = {}
  var focused = ""
  for (var i = 0; i < list.length; i++) {
    var monitor = list[i]
    if (!monitor)
      continue
    var name = String(monitor.name || "").trim().toLowerCase()
    if (!name)
      continue
    var workspace = monitor.activeWorkspace
    var id = workspace ? String(workspace.id) : ""
    if (id)
      byName[name] = id
    // The initial QML focus flag can lag the compositor snapshot.
    var ipc = monitor.lastIpcObject
    if (ipc && typeof ipc.focused === "boolean" ? ipc.focused : monitor.focused)
      focused = name
  }
  state.monitors = byName
  state.focusedMonitor = focused
}

function hasRealScreen(screens) {
  var list = screens || []
  for (var i = 0; i < list.length; i++) {
    var screen = list[i]
    var name = screen ? String(screen.name || "").trim() : ""
    if (screen && name && name.toUpperCase() !== "FALLBACK"
        && Number(screen.width) > 0 && Number(screen.height) > 0)
      return true
  }
  return false
}

function windowCount(state) {
  var count = 0
  for (var key in state.windows)
    if (state.windows[key])
      count += 1
  return count
}

function ignoredCount(state) {
  var count = 0
  for (var key in state.ignored)
    if (state.ignored[key])
      count += 1
  return count
}

function monitorCount(state) {
  var count = 0
  for (var key in state.monitors)
    if (state.monitors[key])
      count += 1
  return count
}
