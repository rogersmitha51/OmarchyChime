// Omarchy Chime — desktop event sounds, system volume/power cues, and
// notification cues.
//
// Independent service plugin (nick.chime). This file is a small composition
// root only: it wires the ChimeController (audio/settings), DesktopEvents
// (window/workspace adapter), SystemEvents (volume/power adapter), and
// NotificationEvents (passive notification observer) slices together,
// resolves the original DND/lock/idle services for conservative safety
// gating, and exposes the `chime` IPC surface. It owns no notification
// daemon, popup, history, or DND state — the built-in omarchy.notifications
// service keeps all of that.

import QtQuick
import Quickshell
import Quickshell.Io
import "ChimeLogic.js" as ChimeLogic

Item {
    id: service

    // Injected by omarchy-shell (the first-party service loader).
    property var shell: null
    property var pluginRegistry: null
    property var manifest: null
    property string omarchyPath: ""

    // Public API exposed to panels (e.g. the Settings.qml panel). This is
    // the single source of truth: a direct alias to the controller slice
    // declared below, never a wrapper or adapter.
    readonly property alias controllerApi: controller

    // ------------------------------------------------------------ slices

    ChimeController {
        id: controller
        // Safety gating is supplied by this composition root (see below).
        safetyReady: service.safetyReady
        desktopReady: adapter.ready
        systemReady: systemAdapter.ready
        overlapBlocked: service.overlapBlocked
        notificationReady: observer.ready
    }

    DesktopEvents {
        id: adapter
        // The adapter monitors whenever the session is safe. Overlap and mute
        // are the controller's playback decision, not the adapter's.
        active: service.safetyReady
        onEventOccurred: function (eventName) {
            controller.playEvent(eventName);
        }
    }

    SystemEvents {
        id: systemAdapter
        // The system adapter monitors the same safety boundary as the desktop
        // adapter: volume/power events only sound while the session is safe.
        // Overlap and mute are the controller's playback decision.
        active: service.safetyReady
        onEventOccurred: function (eventName) {
            controller.playEvent(eventName);
        }
    }

    NotificationEvents {
        id: observer
        // The observer runs only while the session is safe AND the controller
        // has decided its settings, is unmuted, and has notifications
        // enabled. It never depends on desktop activation, ui-sounds overlap,
        // or desktop adapter readiness: a notification is relevant even when
        // desktop sounds are off. `active` is the host's decision; the
        // observer owns its own readiness settling and process lifecycle.
        active: service.safetyReady && controller.settingsReady && controller.enabled && controller.notificationsEnabled
        onEventOccurred: function (eventName) {
            controller.playEvent(eventName);
        }
    }

    // ------------------------------------------------------------ safety

    // Conservative gating: the original DND, lock, and idle services must be
    // present with valid state, the session must actually be unlocked,
    // non-idle, and not in DND, a real screen must exist, and startup must
    // have settled. Until every gate is satisfied, no desktop events are
    // tracked and no sound plays.

    // The shell replaces its _services map wholesale on every sync (reload,
    // enable/disable, plugin scan). Binding to the live map makes the
    // serviceFor lookups below re-resolve whenever the map is replaced.
    readonly property var _services: service.shell && typeof service.shell._services === "object" ? service.shell._services : null

    readonly property var _dndService: service._services ? service._serviceFor("omarchy.notifications") : null
    readonly property var _lockService: service._services ? service._serviceFor("omarchy.lock") : null
    readonly property var _idleService: service._services ? service._serviceFor("omarchy.idle") : null

    readonly property bool dndPresent: service._dndService !== null
    readonly property bool lockPresent: service._lockService !== null
    readonly property bool idlePresent: service._idleService !== null
    readonly property bool dndValid: service.dndPresent && typeof service._dndService.doNotDisturb === "boolean"
    readonly property bool lockValid: service.lockPresent && typeof service._lockService.locked === "boolean"
    readonly property bool idleValid: service.idlePresent && typeof service._idleService.idledThisCycle === "boolean" && typeof service._idleService.screensaverStartedThisCycle === "boolean" && typeof service._idleService.screensaverWindowCount === "number" && isFinite(service._idleService.screensaverWindowCount) && service._idleService.screensaverWindowCount >= 0
    readonly property bool servicesValid: service.dndValid && service.lockValid && service.idleValid

    // Actual session state. Any of these active means the user is not in a
    // state where desktop sounds are wanted.
    readonly property bool dndActive: service.dndValid && service._dndService.doNotDisturb
    readonly property bool locked: service.lockValid && service._lockService.locked
    readonly property bool idleActive: service.idleValid && (service._idleService.idledThisCycle || service._idleService.screensaverStartedThisCycle || service._idleService.screensaverWindowCount > 0)
    readonly property bool sessionSafe: !service.dndActive && !service.locked && !service.idleActive

    readonly property bool hasRealScreen: {
        var screens = Quickshell.screens || [];
        for (var i = 0; i < screens.length; i++) {
            var screen = screens[i];
            if (screen && screen.name && String(screen.name).toUpperCase() !== "FALLBACK" && screen.width > 0 && screen.height > 0)
                return true;
        }
        return false;
    }

    // Startup settles once the shell has finished its first service sync and
    // a real screen has appeared. The gate re-arms whenever the resolved
    // services change identity (reload/replacement) or the real screen is
    // lost and recovered, so a fresh service instance or a hotplugged output
    // gets a fresh grace period.
    property bool startupSettled: false

    readonly property bool safetyReady: service.servicesValid && service.sessionSafe && service.hasRealScreen && service.startupSettled

    readonly property string safetyReason: {
        if (!service.servicesValid)
            return "required services missing or invalid";
        if (service.dndActive)
            return "do not disturb active";
        if (service.locked)
            return "session locked";
        if (service.idleActive)
            return "session idle";
        if (!service.hasRealScreen)
            return "no real screen";
        if (!service.startupSettled)
            return "startup not settled";
        return "ok";
    }

    // ------------------------------------------------------------ overlap

    // gobijan.ui-sounds already plays desktop feedback sounds. When it is
    // enabled (or its state is unknown), Chime must not play desktop events.
    // Only a strict `false` clears the block, so a missing registry or an
    // undefined enable state can never cause double sounds. registryRevision
    // is bound so enable-state changes re-evaluate this gate.
    readonly property int _registryRevision: {
        var registry = service.pluginRegistry;
        return registry && typeof registry.registryRevision === "number" ? registry.registryRevision : 0;
    }

    readonly property bool overlapBlocked: {
        var revision = service._registryRevision;
        var registry = service.pluginRegistry;
        if (!registry || typeof registry.isEnabled !== "function")
            return true;
        try {
            return registry.isEnabled("gobijan.ui-sounds") !== false;
        } catch (e) {
            console.warn("chime: pluginRegistry.isEnabled failed: " + e);
            return true;
        }
    }

    // ------------------------------------------------------------ service map

    function _serviceFor(pluginId) {
        var host = service.shell;
        if (!host || typeof host.serviceFor !== "function")
            return null;
        try {
            return host.serviceFor(String(pluginId)) || null;
        } catch (e) {
            console.warn("chime: serviceFor(" + pluginId + ") failed: " + e);
            return null;
        }
    }

    // ------------------------------------------------------------ startup

    Timer {
        id: settleTimer
        interval: 1500
        repeat: false
        onTriggered: service.startupSettled = true
    }

    function _armSettle() {
        service.startupSettled = false;
        settleTimer.restart();
    }

    // Identity of the resolved DND/lock/idle service objects. Re-evaluates
    // whenever the shell replaces its _services map; the handler below skips
    // replacements that leave the required services unchanged.
    readonly property var _serviceIdentity: [service._dndService, service._lockService, service._idleService]
    property var _lastServiceIdentity: null

    on_ServiceIdentityChanged: {
        var next = service._serviceIdentity;
        var prev = service._lastServiceIdentity;
        if (prev !== null && prev.length === next.length) {
            var same = true;
            for (var i = 0; i < next.length; i++) {
                if (next[i] !== prev[i]) {
                    same = false;
                    break;
                }
            }
            if (same)
                return;
        }
        service._lastServiceIdentity = next;
        service._armSettle();
    }

    onHasRealScreenChanged: {
        if (service.hasRealScreen) {
            // First real screen or recovery after loss: (re-)arm the grace.
            service._armSettle();
        } else {
            // Real screen lost: the grace gate must re-arm on recovery.
            service.startupSettled = false;
            settleTimer.stop();
        }
    }

    Component.onCompleted: {
        if (service.hasRealScreen)
            service._armSettle();
    }

    // ------------------------------------------------------------ IPC

    IpcHandler {
        target: "chime"

        function status(): string {
            return service.statusJson();
        }

        function mute(): string {
            return controller.setEnabled(false);
        }

        function unmute(): string {
            return controller.setEnabled(true);
        }

        function volume(value: string): string {
            var v = String(value || "").trim();
            if (v === "" || isNaN(Number(v)))
                return "error: volume must be a number";
            return controller.setVolume(Number(v));
        }

        function desktop(value: string): string {
            var v = String(value || "").trim().toLowerCase();
            if (v !== "on" && v !== "off")
                return "error: desktop must be on or off";
            return controller.setDesktopEnabled(v === "on");
        }

        function notifications(value: string): string {
            var v = String(value || "").trim().toLowerCase();
            if (v !== "on" && v !== "off")
                return "error: notifications must be on or off";
            return controller.setNotificationsEnabled(v === "on");
        }

        // Issue #7: per-event sound assignment. `sound <event> <soundId>`
        // assigns; `sound` alone lists every event's current assignment;
        // `sounds` lists the catalog.
        function sound(eventName: string, soundId: string): string {
            var ev = String(eventName || "").trim();
            var id = String(soundId || "").trim();
            if (ev === "")
                return controller.eventSounds ? service.soundsSummary() : "error: sound requires an event name";
            if (id === "")
                return "error: sound requires a sound id (see: chime sounds)";
            return controller.setEventSound(ev, id);
        }

        function sounds(): string {
            var ids = controller.soundIds || [];
            var out = "sounds:";
            for (var i = 0; i < ids.length; i++)
                out += " " + ids[i];
            return out;
        }

        function preview(eventName: string): string {
            var name = String(eventName || "").trim();
            if (name === "")
                return "error: preview requires an event name";
            return controller.preview(name);
        }

        function help(): string {
            return "chime commands: status, mute, unmute, volume <0-1>, desktop on|off, notifications on|off, sound <event> <soundId>, sounds, sound <event>, preview <eventName>, help";
        }
    }

    // One line per event: "event -> soundId", for the bare `sound` query.
    function soundsSummary() {
        var lines = [];
        var ids = ChimeLogic.EVENT_IDS;
        for (var i = 0; i < ids.length; i++) {
            var ev = ids[i];
            lines.push(ev + " -> " + ChimeLogic.eventSoundId(ev, controller.eventSounds));
        }
        return lines.join("\n");
    }

    function statusJson() {
        return JSON.stringify({
            plugin: "nick.chime",
            version: "0.3.0",
            safety: {
                ready: service.safetyReady,
                reason: service.safetyReason,
                dndPresent: service.dndPresent,
                dndValid: service.dndValid,
                dndActive: service.dndActive,
                lockPresent: service.lockPresent,
                lockValid: service.lockValid,
                locked: service.locked,
                idlePresent: service.idlePresent,
                idleValid: service.idleValid,
                idleActive: service.idleActive,
                realScreen: service.hasRealScreen,
                startupSettled: service.startupSettled
            },
            overlap: {
                blocked: service.overlapBlocked,
                reason: service.overlapReason()
            },
            controller: controller.status(),
            adapter: adapter.status(),
            system: systemAdapter.status(),
            notification: observer.status()
        });
    }

    function overlapReason() {
        var registry = service.pluginRegistry;
        if (!registry || typeof registry.isEnabled !== "function")
            return "plugin registry unavailable";
        try {
            var enabled = registry.isEnabled("gobijan.ui-sounds");
            if (enabled === false)
                return "gobijan.ui-sounds disabled";
            if (enabled === true)
                return "gobijan.ui-sounds enabled";
            return "gobijan.ui-sounds state unknown";
        } catch (e) {
            return "plugin registry error";
        }
    }
}
