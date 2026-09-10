// Real Quickshell runtime regression harness for the Chime service's
// host-service safety bindings.
//
// This file is loaded as a component by a thin wrapper shell.qml (parent
// launches `qs -p <configdir>` with a real Wayland session and an isolated
// XDG_CONFIG_HOME). The wrapper must create this component and parent it to
// its ShellRoot:
//
//   ShellRoot {
//     id: root
//     Component.onCompleted: {
//       var comp = Qt.createComponent("tests/service-safety.qml")
//       if (comp.status !== Component.Ready) {
//         console.error("CHIME_WRAPPER_COMPONENT_ERROR " + comp.errorString())
//         return
//       }
//       comp.createObject(root)
//     }
//   }
//
// `import ".." as Chime` resolves to the config root, so the real product
// Service/ChimeController/DesktopEvents are exercised — never mocks of the
// product. The harness injects fake host objects (shell._services/serviceFor
// and pluginRegistry.isEnabled/registryRevision) exactly like omarchy-shell's
// service loader, then drives observable service-state transitions through
// the real statusJson() output.
//
// Success: prints CHIME_SERVICE_SAFETY_PASS and exits 0.
// Failure: prints CHIME_SERVICE_SAFETY_FAIL <step>: <detail> and exits nonzero.
//
// The harness never calls preview, never enables desktop sounds, and never
// touches desktop state or user settings.

import QtQuick
import Quickshell
import ".." as Chime

ShellRoot {
  id: harness

  // ------------------------------------------------------------ fakes

  QtObject {
    id: fakeShell
    property var _services: ({})
    function serviceFor(pluginId) {
      return fakeShell._services[String(pluginId)] || null
    }
  }

  QtObject {
    id: fakeRegistry
    property int registryRevision: 0
    property var enabledState: undefined
    function isEnabled(pluginId) {
      return fakeRegistry.enabledState
    }
  }

  QtObject {
    id: fakeDnd
    property var doNotDisturb: false
  }

  QtObject {
    id: fakeLock
    property var locked: false
  }

  QtObject {
    id: fakeIdle
    property var idledThisCycle: false
    property var screensaverStartedThisCycle: false
    property var screensaverWindowCount: 0
  }

  // Replacement instances for the wholesale _services swap test.
  QtObject {
    id: fakeDnd2
    property var doNotDisturb: false
  }

  QtObject {
    id: fakeLock2
    property var locked: false
  }

  QtObject {
    id: fakeIdle2
    property var idledThisCycle: false
    property var screensaverStartedThisCycle: false
    property var screensaverWindowCount: 0
  }

  // ------------------------------------------------------------ product

  Chime.Service {
    id: service
  }

  // ------------------------------------------------------------ machine

  property int step: 0
  property bool waiting: false
  property var waitCond: null
  property var waitDeadline: 0
  property string waitLabel: ""
  property bool finished: false
  property var _originalServices: null
  property var _oldMutateT0: 0

  Timer {
    id: machine
    interval: 50
    repeat: true
    onTriggered: harness.advance()
  }

  Timer {
    id: exitTimer
    interval: 1
    repeat: false
    property int code: 0
    onTriggered: harness._exit(exitTimer.code)
  }

  Timer {
    id: watchdog
    interval: 60000
    repeat: false
    onTriggered: harness.fail("global timeout", "harness did not finish within 60s")
  }

  function status() {
    var text
    try {
      text = service.statusJson()
    } catch (e) {
      harness.fail("statusJson", "statusJson() threw: " + e)
      return null
    }
    var parsed
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      harness.fail("statusJson", "statusJson() is not valid JSON: " + e)
      return null
    }
    return parsed
  }

  function check(cond, label) {
    if (!cond)
      harness.fail(label, "assertion failed")
  }

  function beginWait(cond, label, timeoutMs) {
    harness.waiting = true
    harness.waitCond = cond
    harness.waitLabel = label
    harness.waitDeadline = Date.now() + timeoutMs
  }

  function advance() {
    if (harness.finished)
      return
    if (harness.waiting) {
      var ok = false
      try {
        ok = harness.waitCond()
      } catch (e) {
        harness.fail(harness.waitLabel, "wait condition threw: " + e)
        return
      }
      if (ok) {
        harness.waiting = false
        harness.step++
      } else if (Date.now() > harness.waitDeadline) {
        harness.fail(harness.waitLabel, "timed out waiting")
        return
      }
      return
    }
    harness.runStep()
  }

  function runStep() {
    var labels = ["inject host fakes", "initial ready state", "dnd on", "dnd off", "lock on", "unlock", "idle on", "idle off", "screensaver started on", "screensaver window count on", "screensaver window count off", "invalid dnd type", "valid dnd restored", "missing services", "null shell", "services restored", "wholesale replacement", "old instance mutations", "registry unknown", "registry strict false", "registry true", "registry missing + pass"]
    console.log("CHIME_SERVICE_SAFETY_STEP " + harness.step + " " + labels[harness.step])
    switch (harness.step) {
    case 0:
      harness.step0()
      break
    case 1:
      harness.step1()
      break
    case 2:
      harness.step2()
      break
    case 3:
      harness.step3()
      break
    case 4:
      harness.step4()
      break
    case 5:
      harness.step5()
      break
    case 6:
      harness.step6()
      break
    case 7:
      harness.step7()
      break
    case 8:
      harness.step8()
      break
    case 9:
      harness.step9()
      break
    case 10:
      harness.step10()
      break
    case 11:
      harness.step11()
      break
    case 12:
      harness.step12()
      break
    case 13:
      harness.step13()
      break
    case 14:
      harness.step13b()
      break
    case 15:
      harness.step14()
      break
    case 16:
      harness.step15()
      break
    case 17:
      harness.step16()
      break
    case 18:
      harness.step17()
      break
    case 19:
      harness.step18()
      break
    case 20:
      harness.step19()
      break
    case 21:
      harness.step20()
      break
    default:
      harness.fail("machine", "unexpected step " + harness.step)
    }
  }

  function step0() {
    service.shell = fakeShell
    service.pluginRegistry = fakeRegistry
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === true
    }, "initial ready", 15000)
  }

  function step1() {
    var s = harness.status()
    harness.check(s.safety.ready === true, "initial ready")
    harness.check(s.safety.dndPresent === true && s.safety.dndValid === true, "dnd present and valid")
    harness.check(s.safety.lockPresent === true && s.safety.lockValid === true, "lock present and valid")
    harness.check(s.safety.idlePresent === true && s.safety.idleValid === true, "idle present and valid")
    harness.check(s.safety.realScreen === true, "real screen")
    harness.check(s.safety.startupSettled === true, "startup settled")
    harness.check(s.safety.dndActive === false && s.safety.locked === false && s.safety.idleActive === false, "session safe")
    harness.check(s.overlap.blocked === true, "unknown registry blocks overlap")
    fakeDnd.doNotDisturb = true
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === false
    }, "dnd blocks ready", 5000)
  }

  function step2() {
    var s = harness.status()
    harness.check(s.safety.dndActive === true, "dnd active")
    harness.check(s.adapter.active === false, "adapter inactive while dnd")
    fakeDnd.doNotDisturb = false
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === true
    }, "dnd cleared", 5000)
  }

  function step3() {
    fakeLock.locked = true
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === false
    }, "lock blocks ready", 5000)
  }

  function step4() {
    var s = harness.status()
    harness.check(s.safety.locked === true, "locked")
    fakeLock.locked = false
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === true
    }, "unlock restores ready", 5000)
  }

  function step5() {
    fakeIdle.idledThisCycle = true
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === false
    }, "idle blocks ready", 5000)
  }

  function step6() {
    var s = harness.status()
    harness.check(s.safety.idleActive === true, "idle active")
    fakeIdle.idledThisCycle = false
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === true
    }, "idle cleared", 5000)
  }

  function step7() {
    fakeIdle.screensaverStartedThisCycle = true
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === false
    }, "screensaver started blocks ready", 5000)
  }

  function step8() {
    var s = harness.status()
    harness.check(s.safety.idleActive === true, "screensaver started active")
    fakeIdle.screensaverStartedThisCycle = false
    fakeIdle.screensaverWindowCount = 1
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === false
    }, "screensaver window count blocks ready", 5000)
  }

  function step9() {
    var s = harness.status()
    harness.check(s.safety.idleActive === true, "screensaver window count active")
    fakeIdle.screensaverWindowCount = 0
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === true
    }, "screensaver window count cleared", 5000)
  }

  function step10() {
    fakeDnd.doNotDisturb = "yes"
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === false
    }, "invalid dnd type blocks ready", 5000)
  }

  function step11() {
    var s = harness.status()
    harness.check(s.safety.dndValid === false, "dnd invalid")
    harness.check(s.safety.dndPresent === true, "dnd still present")
    fakeDnd.doNotDisturb = false
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === true
    }, "valid dnd restores ready", 5000)
  }

  function step12() {
    fakeShell._services = {}
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === false
    }, "missing services block ready", 5000)
  }

  function step13() {
    var s = harness.status()
    harness.check(s.safety.dndPresent === false, "dnd missing")
    harness.check(s.safety.lockPresent === false, "lock missing")
    harness.check(s.safety.idlePresent === false, "idle missing")
    // Null shell: serviceFor is unavailable, so every service is missing.
    service.shell = null
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.dndPresent === false
    }, "null shell reports missing services", 5000)
  }

  function step13b() {
    var s = harness.status()
    harness.check(s.safety.ready === false, "null shell not ready")
    harness.check(s.safety.lockPresent === false && s.safety.idlePresent === false, "null shell all missing")
    service.shell = fakeShell
    fakeShell._services = harness._originalServices
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === true
    }, "restored services ready", 15000)
  }

  function step14() {
    fakeShell._services = {
      "omarchy.notifications": fakeDnd2,
      "omarchy.lock": fakeLock2,
      "omarchy.idle": fakeIdle2
    }
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.safety.ready === true
    }, "replacement services ready", 15000)
  }

  function step15() {
    fakeDnd.doNotDisturb = true
    fakeLock.locked = true
    fakeIdle.idledThisCycle = true
    harness._oldMutateT0 = Date.now()
    harness.beginWait(function () {
      return Date.now() >= harness._oldMutateT0 + 200
    }, "old instance mutation grace", 5000)
  }

  function step16() {
    var s = harness.status()
    harness.check(s.safety.ready === true, "old instance mutations ignored")
    harness.check(s.safety.dndActive === false, "old dnd mutation ignored")
    harness.check(s.safety.locked === false, "old lock mutation ignored")
    harness.check(s.safety.idleActive === false, "old idle mutation ignored")
    fakeRegistry.enabledState = undefined
    fakeRegistry.registryRevision++
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.overlap.blocked === true
    }, "unknown registry blocks overlap", 5000)
  }

  function step17() {
    var s = harness.status()
    harness.check(s.overlap.blocked === true, "unknown registry blocked")
    harness.check(s.safety.ready === true, "overlap does not affect safety")
    harness.check(s.adapter.active === true, "overlap does not affect adapter active")
    fakeRegistry.enabledState = false
    fakeRegistry.registryRevision++
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.overlap.blocked === false
    }, "strict false clears overlap", 5000)
  }

  function step18() {
    var s = harness.status()
    harness.check(s.overlap.blocked === false, "strict false cleared")
    harness.check(s.adapter.active === true, "adapter active independent of overlap")
    fakeRegistry.enabledState = true
    fakeRegistry.registryRevision++
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.overlap.blocked === true
    }, "true blocks overlap", 5000)
  }

  function step19() {
    var s = harness.status()
    harness.check(s.overlap.blocked === true, "true blocked")
    service.pluginRegistry = null
    harness.beginWait(function () {
      var st = harness.status()
      return st && st.overlap.blocked === true
    }, "missing registry blocks overlap", 5000)
  }

  function step20() {
    var s = harness.status()
    harness.check(s.overlap.blocked === true, "missing registry blocked")
    harness.check(s.safety.ready === true, "safety unaffected by registry")
    harness.pass()
  }

  function pass() {
    harness.finished = true
    machine.stop()
    watchdog.stop()
    console.log("CHIME_SERVICE_SAFETY_PASS")
    exitTimer.code = 0
    exitTimer.restart()
  }

  function fail(stepLabel, detail) {
    if (harness.finished)
      return
    harness.finished = true
    machine.stop()
    watchdog.stop()
    console.error("CHIME_SERVICE_SAFETY_FAIL " + stepLabel + ": " + detail)
    exitTimer.code = 1
    exitTimer.restart()
  }

  function _exit(code) {
    Qt.exit(code)
  }

  Component.onCompleted: {
    harness._originalServices = {
      "omarchy.notifications": fakeDnd,
      "omarchy.lock": fakeLock,
      "omarchy.idle": fakeIdle
    }
    fakeShell._services = harness._originalServices
    service.shell = fakeShell
    service.pluginRegistry = fakeRegistry
    machine.start()
    watchdog.start()
  }
}
