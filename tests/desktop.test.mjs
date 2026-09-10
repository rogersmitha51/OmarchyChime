// Deterministic regression tests for the desktop event adapter's pure state
// machine (DesktopLogic.js). Runs under node:test; the QML pragma line is
// stripped and the library is evaluated in a vm context so no QML runtime is
// needed.
//
// The tests exercise the real Hyprland IPC protocol: workspacev2 carries
// WORKSPACEID,WORKSPACENAME and is attributed to the remembered focused
// monitor; focusedmonv2 carries MONNAME,WORKSPACEID and only moves focus.

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "DesktopLogic.js"), "utf8")
  .replace(/^\.pragma library\s*\n/, "")

const context = vm.createContext({})
vm.runInContext(source, context, { filename: "DesktopLogic.js" })
const Logic = context

function event(name, data) {
  return { name, data }
}

// Installed HyprlandToplevel has no `class` property; the class is read from
// lastIpcObject.class. Plain fixtures may pass `class` directly.
function toplevel(address, klass) {
  return { address, class: klass }
}

function toplevelFromIpc(address, klass) {
  return { address, lastIpcObject: { class: klass } }
}

function monitor(name, workspaceId, focused) {
  return { name, activeWorkspace: { id: workspaceId }, focused: focused === true }
}

test("seeded window address normalization: 0x-prefixed and bare hex are the same window", () => {
  const state = Logic.newState()
  Logic.seedWindows(state, [toplevel("0xabc", "firefox")])
  // The same window reported without the 0x prefix is a duplicate, not a new open.
  assert.equal(Logic.handleEvent(state, event("openwindow", "abc,1,firefox,Title")), "")
  // Its close, reported bare, is the seeded window's real close.
  assert.equal(Logic.handleEvent(state, event("closewindow", "abc")), "windowClosed")

  const reverse = Logic.newState()
  Logic.seedWindows(reverse, [toplevel("abc", "kitty")])
  assert.equal(Logic.handleEvent(reverse, event("openwindow", "0xabc,1,kitty,Title")), "")
  assert.equal(Logic.handleEvent(reverse, event("closewindow", "0xabc")), "windowClosed")
})

test("seeded ignored class from lastIpcObject.class stays silent on close", () => {
  const state = Logic.newState()
  Logic.seedWindows(state, [toplevelFromIpc("0x10", "xdph-picker")])
  assert.equal(Logic.ignoredCount(state), 1)
  assert.equal(Logic.handleEvent(state, event("closewindow", "0x10")), "")
  assert.equal(Logic.ignoredCount(state), 0)
})

test("reseed replaces the window set: stale windows are forgotten", () => {
  const state = Logic.newState()
  Logic.seedWindows(state, [toplevel("0x30", "firefox")])
  // A later snapshot without the first window replaces the set.
  Logic.seedWindows(state, [toplevel("0x31", "kitty")])
  // The stale window's close is unknown chatter, not an event...
  assert.equal(Logic.handleEvent(state, event("closewindow", "0x30")), "")
  // ...and reopening it is a real event again.
  assert.equal(Logic.handleEvent(state, event("openwindow", "0x30,1,firefox,Title")), "windowOpened")
  // The current seeded window still closes as a real event.
  assert.equal(Logic.handleEvent(state, event("closewindow", "0x31")), "windowClosed")
})

test("ignored classes: open and close are both silent, close remembered", () => {
  const state = Logic.newState()
  assert.equal(Logic.handleEvent(state, event("openwindow", "0x11,1,xdph-picker,Title")), "")
  assert.equal(Logic.ignoredCount(state), 1)
  assert.equal(Logic.handleEvent(state, event("closewindow", "0x11")), "")
  assert.equal(Logic.ignoredCount(state), 0)
  assert.equal(Logic.handleEvent(state, event("openwindow", "0x12,1,firefox,Title")), "windowOpened")
})

test("duplicate open/close: exactly one event per real transition", () => {
  const state = Logic.newState()
  assert.equal(Logic.handleEvent(state, event("openwindow", "0x20,1,firefox,Title")), "windowOpened")
  assert.equal(Logic.handleEvent(state, event("openwindow", "0x20,1,firefox,Title")), "")
  assert.equal(Logic.handleEvent(state, event("closewindow", "0x20")), "windowClosed")
  assert.equal(Logic.handleEvent(state, event("closewindow", "0x20")), "")
  assert.equal(Logic.handleEvent(state, event("closewindow", "0x999")), "")
})

test("workspacev2 carries workspace id and name; transitions emit only on change", () => {
  const state = Logic.newState()
  Logic.seedMonitors(state, [monitor("DP-1", 1, true)])
  // Repeat of the seeded workspace: silent.
  assert.equal(Logic.handleEvent(state, event("workspacev2", "1,workspace-1")), "")
  // A real transition emits.
  assert.equal(Logic.handleEvent(state, event("workspacev2", "2,workspace-2")), "workspaceSwitched")
  // Same workspace again: silent.
  assert.equal(Logic.handleEvent(state, event("workspacev2", "2,workspace-2")), "")
  // Back to the original emits again.
  assert.equal(Logic.handleEvent(state, event("workspacev2", "1,workspace-1")), "workspaceSwitched")
})

test("initial compositor focus snapshot enables workspace sounds before focus signals", () => {
  const state = Logic.newState()
  Logic.seedMonitors(state, [{
    name: "eDP-1",
    focused: false,
    lastIpcObject: { focused: true },
    activeWorkspace: { id: 1 }
  }])
  assert.equal(Logic.handleEvent(state, event("workspacev2", "2,2")), "workspaceSwitched")
  assert.equal(Logic.handleEvent(state, event("workspacev2", "2,2")), "")
})

test("workspacev2 with no focused monitor is silent and records nothing", () => {
  const state = Logic.newState()
  // No monitor is focused yet: the event cannot be attributed, so it is silent
  // and must not establish a baseline.
  assert.equal(Logic.handleEvent(state, event("workspacev2", "2,workspace-2")), "")
  // Once a monitor is seeded as focused, the same workspace is a fresh baseline:
  // reporting it is a real transition.
  Logic.seedMonitors(state, [monitor("DP-1", 1, true)])
  assert.equal(Logic.handleEvent(state, event("workspacev2", "2,workspace-2")), "workspaceSwitched")
})

test("focusedmonv2 only moves focus; workspace transitions still emit", () => {
  const state = Logic.newState()
  Logic.seedMonitors(state, [monitor("DP-1", 1, true), monitor("HDMI-A-1", 2, false)])
  // Focus-only reports are silent, even for the already-focused monitor.
  assert.equal(Logic.handleEvent(state, event("focusedmonv2", "DP-1,1")), "")
  // Focus moves to HDMI-A-1; the reported workspace is not a transition baseline.
  assert.equal(Logic.handleEvent(state, event("focusedmonv2", "HDMI-A-1,5")), "")
  // The real per-monitor transition (seeded 2 -> 5) still emits.
  assert.equal(Logic.handleEvent(state, event("workspacev2", "5,workspace-5")), "workspaceSwitched")
  // And the repeat is silent.
  assert.equal(Logic.handleEvent(state, event("workspacev2", "5,workspace-5")), "")
})

test("same-monitor repeat vs multi-monitor focus: per-monitor and independent", () => {
  const state = Logic.newState()
  Logic.seedMonitors(state, [monitor("DP-1", 1, true), monitor("HDMI-A-1", 2, false)])

  // Re-focusing the already-focused monitor is silent; DP-1 repeats its workspace.
  assert.equal(Logic.handleEvent(state, event("focusedmonv2", "DP-1,1")), "")
  assert.equal(Logic.handleEvent(state, event("workspacev2", "1,workspace-1")), "")

  // Focus moves to HDMI-A-1; its transition 2 -> 3 emits.
  assert.equal(Logic.handleEvent(state, event("focusedmonv2", "HDMI-A-1,2")), "")
  assert.equal(Logic.handleEvent(state, event("workspacev2", "3,workspace-3")), "workspaceSwitched")

  // Focus back to DP-1: its workspace is unchanged, so the repeat is silent.
  assert.equal(Logic.handleEvent(state, event("focusedmonv2", "DP-1,1")), "")
  assert.equal(Logic.handleEvent(state, event("workspacev2", "1,workspace-1")), "")
  // DP-1's own transition still emits independently.
  assert.equal(Logic.handleEvent(state, event("workspacev2", "4,workspace-4")), "workspaceSwitched")
})

test("malformed events are ignored, not thrown", () => {
  const state = Logic.newState()
  Logic.seedMonitors(state, [monitor("DP-1", 1, true)])
  assert.equal(Logic.handleEvent(state, event("openwindow", "")), "")
  assert.equal(Logic.handleEvent(state, event("closewindow", "")), "")
  assert.equal(Logic.handleEvent(state, event("workspacev2", "")), "")
  assert.equal(Logic.handleEvent(state, event("focusedmonv2", "")), "")
  assert.equal(Logic.handleEvent(state, event("focusedmonv2", ",1")), "")
  assert.equal(Logic.handleEvent(state, event("unknown", "1,2,3")), "")
  assert.equal(Logic.handleEvent(state, null), "")
  assert.equal(Logic.handleEvent(state, {}), "")
})
