// Theme-pack and event-sound runtime probe: loads the REAL ChimeController
// against an isolated XDG config seeded with a complete v3 file. Verifies:
//   1. the v3 -> v4 migration (default sounds seeded, file rewritten v4)
//   2. per-event assignment + persistence and API validation
//   3. whole-pack selection + persistence, derived pack state, and playback path
//   4. preview preemption: a preview arriving while a preview owns the
//   5. same-direction volume repeats coalesce; reversals preempt immediately
//   6. "none" silence: an event assigned none never claims the voice
//   7. preview-vs-automatic bounds (busy) and cooldown policy
// Never touches the real desktop state. Audio may play during the preview
// steps (the seed volume is 0, so it is inaudible).
//
// Maintainer-only, live-desktop harness (modeled on
// tests/service-safety.qml): copy this file to the ROOT of a scratch copy
// of the plugin tree and run `XDG_CONFIG_HOME=<scratch>/omarchy qs -n -p
// <scratch>`; `import "."` then resolves to the product root (the file
// sits next to ChimeController.qml there). The harness must create the
// isolated XDG parent and seed <scratch>/omarchy/omarchy/chime.json
// (schema v3) before launch — the controller's FileView cannot watch a
// missing parent.
import QtQuick
import Quickshell
import Quickshell.Io
import "." as Chime

ShellRoot {
    id: probe

    property string fail: ""
    property var persisted: null
    property int step: 0

    // The controller under test: the real product component.
    Chime.ChimeController {
        id: controller
        safetyReady: false // flipped on for the preview steps only
        desktopReady: false
        systemReady: false
        notificationReady: false
        overlapBlocked: true
    }

    // Disk reader: the real controller writes through its own FileView (and
    // watches that path itself); a SECOND FileView on the same path sees
    // stale content after reloads (Quickshell double-watcher quirk), so we
    // read the file back through a plain `cat` process instead — no watch,
    // no interference, fresh content every poll.
    property string diskText: ""
    Process {
        id: diskReader
        command: ["cat", "/tmp/chime-probe/omarchy/omarchy/chime.json"]
        stdout: StdioCollector {
            onStreamFinished: probe.diskText = this.text
        }
    }

    function readDisk() {
        diskReader.running = false;
        diskReader.running = true;
    }

    // True once a disk poll has returned parseable JSON.
    function diskParsed() {
        if (diskText === "")
            return null;
        try {
            return JSON.parse(diskText);
        } catch (e) {
            return null;
        }
    }

    Timer {
        id: machine
        interval: 50
        repeat: true
        onTriggered: probe.advance()
    }

    Timer {
        id: exitTimer
        interval: 1
        repeat: false
        property int code: 0
        onTriggered: Qt.exit(code)
    }

    function check(cond, label) {
        if (cond)
            return;
        if (probe.fail === "")
            probe.fail = label;
        console.error("PROBE_FAIL " + label);
    }

    function finish() {
        machine.stop();
        if (probe.fail !== "") {
            console.error("PROBE_RESULT FAIL: " + probe.fail);
            exitTimer.code = 1;
        } else {
            console.error("PROBE_RESULT PASS");
            exitTimer.code = 0;
        }
        exitTimer.start();
    }

    // The step machine: advance() runs the CURRENT step every tick; a step
    // bumps probe.step only once it is done (possibly after waiting), so a
    // wait never skips later steps' preconditions.
    function advance() {
        if (!controller.settingsReady)
            return;
        if (probe.step === 0) {
            probe.step = 1;
            // v3 file must have migrated: settings ready from file, sounds
            check(controller._settingsSource === "file", "v3 adopted from file, got: " + controller._settingsSource);
            console.error("PROBE loaded: " + JSON.stringify(controller.eventSounds));
            var sounds = controller.eventSounds;
            check(sounds.workspaceSwitched === "audio-volume-change", "workspaceSwitched default");
            check(sounds.notificationReceived === "agent-needs-input", "notificationReceived default");
            check(sounds.volumeUp === "audio-volume-change", "volumeUp default");
            check(sounds.volumeDown === "audio-volume-change", "volumeDown default");
            check(sounds.powerConnected === "device-added", "powerConnected default");
        } else if (probe.step === 1) {
            // Assign a different catalog sound through the real API. The
            // first setter call persists the migrated in-memory v4 state, so
            // the file on disk becomes v4 with the sounds map + bell.
            var r = controller.setEventSound("workspaceSwitched", "bell");
            check(r === "workspaceSwitched -> bell", "setEventSound result, got: " + r);
            check(controller.eventSounds.workspaceSwitched === "bell", "assignment visible in eventSounds");
            check(controller._eventAssetPath("workspaceSwitched") === "/usr/share/sounds/freedesktop/stereo/bell.oga", "resolved path for assigned bell");
            probe.readDisk();
            probe.step = 2;
        } else if (probe.step === 2) {
            // Wait for the assignment write to land on disk.
            var d2 = probe.diskParsed();
            if (d2 === null || d2.version !== 4 || !d2.sounds || d2.sounds.workspaceSwitched !== "bell") {
                probe.readDisk();
                return;
            }
            check(d2.sounds.notificationReceived === "agent-needs-input", "untouched event keeps default");
            // API validation: unknown sound and unknown event rejected.
            check(controller.setEventSound("workspaceSwitched", "../etc/passwd") === "unknown sound: ../etc/passwd", "path traversal rejected");
            check(controller.setEventSound("nope", "bell") === "unknown event: nope", "unknown event rejected");
            check(controller.eventSounds.workspaceSwitched === "bell", "assignment unchanged after rejects");
            check(controller.themePack === "custom", "per-event edit derives custom pack");
            var packResult = controller.setThemePack("zen-wood");
            check(packResult === "theme pack -> zen-wood", "setThemePack result, got: " + packResult);
            check(controller.themePack === "zen-wood", "Zen Wood pack visible");
            check(controller._eventAssetPath("workspaceSwitched").indexOf("/assets/packs/zen-wood/workspace-switched.wav") !== -1, "Zen Wood playback path resolved");
            check(controller.setThemePack("missing") === "unknown theme pack: missing", "unknown theme pack rejected");
            probe.readDisk();
            probe.step = 3;
        } else if (probe.step === 3) {
            // Wait for the atomic pack assignment to land on disk.
            var d3 = probe.diskParsed();
            if (d3 === null || !d3.sounds || d3.sounds.workspaceSwitched !== "zen-wood:workspaceSwitched") {
                probe.readDisk();
                return;
            }
            check(d3.sounds.notificationReceived === "zen-wood:notificationReceived", "Zen Wood notification persisted");
            // Catalog and pack exposure for the panel.
            check(controller.soundIds.length === 68, "catalog size 68, got: " + controller.soundIds.length);
            check(controller.soundNoneId === "none", "none exposed as the silence id");
            check(controller.soundCatalog.none.path === "", "none catalog entry has empty path");
            check(controller.soundCatalog["zen-wood:windowOpened"].path === "assets/packs/zen-wood/window-opened.wav", "Zen Wood catalog entry");
            check(controller.themePackIds.length === 7, "seven theme packs exposed");
            var st = controller.status();
            check(st.themePack === "zen-wood", "status carries selected pack");
            check(st.eventSounds && st.eventSounds.workspaceSwitched === "zen-wood:workspaceSwitched", "status carries pack eventSounds");
            probe.step = 4;
        } else if (probe.step === 4) {
            // ---- preview preemption -------------------------------------
            // Safety must be on for previews; keep every other gate off so
            // no automatic playback can interfere.
            controller.safetyReady = true;
            var p1 = controller.preview("windowOpened");
            check(p1 === "windowOpened", "first preview accepted, got: " + p1);
            check(controller.playing === true, "first preview owns the voice");
            // A second preview must interrupt the first: latest-only.
            var p2 = controller.preview("windowClosed");
            check(p2 === "windowClosed", "second preview accepted, got: " + p2);
            check(controller._pendingPreview === "windowClosed", "pending preview retained");
            // A third immediately replaces the retained intent.
            var p3 = controller.preview("workspaceSwitched");
            check(p3 === "workspaceSwitched", "third preview accepted");
            check(controller._pendingPreview === "workspaceSwitched", "pending preview keeps only latest");
            probe.step = 5;
        } else if (probe.step === 5) {
            // The cut first preview has exited; the replacement started.
            if (controller.playing === false && controller._pendingPreview === "workspaceSwitched")
                return; // release path still pending: re-check next tick
            check(controller.playing === true, "replacement preview started");
            check(controller._currentEvent === "workspaceSwitched", "replacement plays latest event, got: " + controller._currentEvent);
            check(controller._pendingPreview === "", "pending preview consumed");
            check(controller._isPreview === true, "replacement is a preview");
            probe.step = 6;
        } else if (probe.step === 6) {
            // After the replacement exits naturally, the cooldown governs
            // the next preview (existing preview policy unchanged). Hold
            // here until the voice is done.
            if (controller.playing)
                return;
            check(controller._cooldownActive === true, "cooldown armed after natural preview exit");
            var p4 = controller.preview("windowOpened");
            check(p4 === "cooldown", "preview during cooldown reported, got: " + p4);
            // A preview must never preempt an automatic cue: start a
            // non-preview automatic event, then preview it — busy.
            controller.setEnabled(true);
            controller.setDesktopEnabled(true);
            controller.desktopReady = true;
            controller.overlapBlocked = false;
            check(controller.desktopEnabled === true, "desktop sounds enabled for automatic test");
            var a1 = controller.playEvent("windowClosed");
            check(a1 === "windowClosed", "automatic event accepted, got: " + a1);
            check(controller._isPreview === false, "automatic owns the voice");
            var p5 = controller.preview("windowOpened");
            check(p5 === "busy", "preview cannot preempt automatic, got: " + p5);
            probe.step = 7;
        } else if (probe.step === 7) {
            // Once the previous automatic cue and cooldown finish, start a
            // tonal volume cue. A same-direction repeat coalesces, but the
            // opposite direction must preempt the stale cue (issue #11).
            if (controller.playing || controller._cooldownActive)
                return;
            controller.setThemePack("retro-hacker");
            controller.systemReady = true;
            var v1 = controller.playEvent("volumeUp");
            var v1Repeat = controller.playEvent("volumeUp");
            check(v1 === "volumeUp" && v1Repeat === "volumeUp", "same-direction volume events accepted");
            check(controller._currentEvent === "volumeUp", "same-direction repeat kept the running cue");
            check(controller._pendingReplacement === "", "same-direction repeat coalesced");
            var v2 = controller.playEvent("volumeDown");
            check(v2 === "volumeDown", "opposite volume event accepted");
            check(controller._pendingReplacement === "volumeDown", "direction reversal retained as replacement");
            check(controller._deliberateStop === true, "direction reversal requested preemption");
            probe.step = 8;
        } else if (probe.step === 8) {
            if (controller._pendingReplacement !== "")
                return;
            check(controller.playing === true, "reversed volume cue started");
            check(controller._currentEvent === "volumeDown", "reversal plays latest direction, got: " + controller._currentEvent);
            check(controller._pendingReplacement === "", "reversal replacement consumed");
            probe.step = 9;
        } else if (probe.step === 9) {
            if (controller.playing || controller._cooldownActive)
                return;
            // Assign "none" and confirm every path reports silence without
            // ever touching the voice. All gates on so each path reaches its
            // silent check: master + desktop (step 6), systemReady for the
            // volumeUp system-event gate, notifications + observer-ready for
            // the notification gate. The observer child itself never starts
            // (NotificationEvents.qml is not instantiated here); only the
            // controller's gate state is exercised.
            controller.setEnabled(true);
            controller.systemReady = true;
            var r1 = controller.setEventSound("volumeUp", "none");
            check(r1 === "volumeUp -> none", "none assignment accepted, got: " + r1);
            check(controller.eventSoundId("volumeUp") === "none", "none survives as the assignment");
            check(controller._eventAssetPath("volumeUp") === "", "none resolves to empty path");
            var a2 = controller.playEvent("volumeUp");
            check(a2 === "silent (volumeUp -> none)", "automatic play reports silent, got: " + a2);
            check(controller.playing === false, "no voice claimed for silent event");
            var pv1 = controller.preview("volumeUp");
            check(pv1 === "silent (volumeUp -> none)", "preview reports silent, got: " + pv1);
            check(controller.playing === false, "no voice claimed for silent preview");
            controller.setEventSound("notificationReceived", "none");
            controller.setNotificationsEnabled(true);
            controller.notificationReady = true;
            var n1 = controller.playNotificationEvent();
            check(n1 === "silent (notificationReceived -> none)", "notification reports silent, got: " + n1);
            check(controller.playing === false, "no voice claimed for silent notification");
            // Restoring a real sound makes the event audible again.
            controller.setEventSound("volumeUp", "audio-volume-change");
            check(controller._eventAssetPath("volumeUp") !== "", "restored assignment resolves to a path");
            probe.step = 10;
        } else if (probe.step === 10) {
            controller.safetyReady = false;
            controller.setDesktopEnabled(false);
            controller.setNotificationsEnabled(false);
            probe.finish();
        }
    }

    Component.onCompleted: {
        machine.start();
    }
}