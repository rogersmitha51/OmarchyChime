// Notification event adapter: turns a supported agent-input notification
// into the single agentNeedsInput event.
//
// This component is deliberately dumb about audio: it reports the
// agent-input event even while the chime's own audio is muted or disabled,
// so the controller can decide what to play. `active` means the host wants
// the observer running — the host binds it to safety && settings ready &&
// enabled && agentInputEnabled. The observer itself is a passive D-Bus
// monitor (notification_observer.py) that never owns the notification
// service and never sends after becoming a monitor.
//
// Readiness is a handshake model. `ready` is false until the observer
// process has started and reported {"type":"ready"} on stdout; it drops
// false on any stop, restart, or error and only returns after a fresh
// handshake. Events are emitted only for fresh accepted notifications
// (observer-side correlation and staleness filtering); nothing is replayed
// and there is no sound queue here.
//
// Lifecycle: `active` true starts the observer and keeps it restarted with
// a bounded delay while true; false stops it and clears readiness. A rapid
// off/on never rearms a child that is still stopping: the actual exit
// clears readiness and schedules the single bounded restart. Output is
// accepted only from a live, started, non-deliberately-stopped generation,
// and events additionally require a completed handshake; malformed or
// unknown protocol fails closed (readiness drops, fixed error token)
// rather than being silently accepted.

import QtQuick
import Quickshell.Io

Item {
    id: root

    // Host-controlled switch. True starts the observer (and keeps it
    // restarted with a bounded delay while true); false stops it and clears
    // readiness. While false no python3 process runs.
    property bool active: false

    readonly property bool ready: root._ready

    // Emitted for exactly the one supported event. Never emitted for stale
    // reports, suppressed notifications, or equal-ID replies.
    signal eventOccurred(string eventName)

    // Transient observer state. Deliberately not persisted: a QML reload
    // must start from a fresh handshake, never from stale pre-reload state.
    property bool _ready: false
    property string _lastError: ""
    property bool _deliberateStop: false
    property bool _childStarted: false
    // True once the current generation has actually exited, so the
    // runningChanged(false) that follows an exit is not mistaken for a
    // FailedToStart (which never emits exited).
    property bool _exitHandled: false

    // Fixed error tokens: the observer's own fail-closed codes plus the
    // adapter-side tokens. Anything else is unknown protocol and fails
    // closed. No private data ever appears here.
    readonly property var _fixedErrorTokens: ["owner-unavailable", "become-monitor-failed", "owner-changed", "disconnected", "internal", "failed-to-start", "observer-exited-unexpectedly", "malformed-output", "unknown-protocol"]

    // The observer is a local plugin asset. Resolved relative to this file
    // through Qt.resolvedUrl so it works from the installed plugin directory
    // regardless of the host shell's working directory. Quickshell strips
    // file:// only from command[0], and the observer path is argv[1], so the
    // prefix is removed here before decoding.
    readonly property string observerPath: {
        var url = Qt.resolvedUrl("notification_observer.py");
        if (!url)
            return "";
        var s = String(url);
        if (s.indexOf("file://") === 0)
            s = s.slice(7);
        return decodeURIComponent(s);
    }

    Process {
        id: observer
        command: ["/usr/bin/python3", root.observerPath]
        stdout: SplitParser {
            onRead: function (line) {
                root._handleLine(String(line));
            }
        }
        // stderr deliberately unset: the channel is closed, so the observer's
        // stderr writes can never EPIPE the plugin.
        onStarted: root._childStarted = true
        onRunningChanged: {
            if (observer.running)
                return;
            if (!root.active || root._deliberateStop || root._exitHandled)
                return;
            if (!root._childStarted) {
                // FailedToStart drops the process without an exited signal; the
                // runningChanged(false) is the only notification. A successful
                // exit is handled in onExited first, so it never reaches here.
                root._ready = false;
                root._lastError = "failed-to-start";
                restartTimer.restart();
            }
        }
    }

    Connections {
        target: observer
        function onExited(exitCode) {
            root._childStarted = false;
            root._exitHandled = true;
            // Any actual exit ends the generation: readiness never survives it.
            root._ready = false;
            if (root.active) {
                // The host still wants the observer. Restart with a bounded
                // delay regardless of whether this exit was deliberate (rapid
                // off/on): the exit is the natural point to rearm. Only an
                // exit we never asked for is an error, and a specific error
                // token already recorded by the observer is kept over the
                // generic one.
                if (!root._deliberateStop && root._lastError === "")
                    root._lastError = "observer-exited-unexpectedly";
                restartTimer.restart();
            }
        }
    }

    Timer {
        id: restartTimer
        interval: 1000
        repeat: false
        onTriggered: {
            if (root.active)
                root._launch();
        }
    }

    onActiveChanged: {
        if (root.active) {
            if (observer.running) {
                // Prior child still stopping (rapid off/on): never rearm it.
                // The actual exit clears readiness and schedules the bounded
                // restart.
                root._ready = false;
            } else {
                // Fresh generation: start now. The deliberate-stop flag is
                // reset only here, at an actual launch.
                root._launch();
            }
        } else {
            // Deactivated: stop the observer, clear readiness, and cancel any
            // pending restart. The destructor also kills the child, so
            // destruction and deactivation both stop it.
            root._deliberateStop = true;
            restartTimer.stop();
            observer.running = false;
            root._ready = false;
        }
    }

    // Start one fresh observer generation. The deliberate-stop flag is reset
    // only here, so a stop requested for a previous generation is never
    // swallowed by a launch that never happened.
    function _launch() {
        root._deliberateStop = false;
        root._exitHandled = false;
        root._childStarted = false;
        root._ready = false;
        root._lastError = "";
        observer.running = true;
    }

    // Fail closed on malformed or unknown protocol: readiness drops and a
    // fixed token is recorded. The process keeps running; only a fresh valid
    // handshake restores readiness.
    function _failClosed(token) {
        root._ready = false;
        root._lastError = token;
    }

    function _isFixedErrorToken(code) {
        if (typeof code !== "string" || code.length === 0 || code.length > 64)
            return false;
        return root._fixedErrorTokens.indexOf(code) !== -1;
    }

    // Handle one newline-delimited JSON line from the observer. Output is
    // accepted only while the host wants the observer, the process is
    // running and has actually started, and no stop was requested — stale or
    // pre-handshake output from a previous generation can never emit or set
    // readiness. Malformed or unknown protocol fails closed instead of being
    // silently accepted.
    function _handleLine(line) {
        if (!root.active || !observer.running || !root._childStarted || root._deliberateStop)
            return;
        if (line.length > 4096) {
            root._failClosed("malformed-output");
            return;
        }
        var obj = null;
        try {
            obj = JSON.parse(line);
        } catch (e) {
            root._failClosed("malformed-output");
            return;
        }
        if (!obj || typeof obj.type !== "string") {
            root._failClosed("malformed-output");
            return;
        }
        if (obj.type === "ready") {
            root._ready = true;
            root._lastError = "";
        } else if (obj.type === "event") {
            // Events additionally require a completed handshake.
            if (!root._ready)
                return;
            if (obj.event !== "agentNeedsInput") {
                root._failClosed("unknown-protocol");
                return;
            }
            // Timestamp must be a real number (coerced values are malformed)
            // and fresh: age in [0, 250] ms. Future and stale reports are
            // rejected without emitting.
            if (typeof obj.timeMs !== "number" || !isFinite(obj.timeMs)) {
                root._failClosed("malformed-output");
                return;
            }
            var age = Date.now() - obj.timeMs;
            if (age < 0 || age > 250)
                return;
            root.eventOccurred("agentNeedsInput");
        } else if (obj.type === "error") {
            var code = String(obj.code || "");
            if (!root._isFixedErrorToken(code)) {
                root._failClosed("unknown-protocol");
                return;
            }
            root._lastError = code;
            root._ready = false;
        } else {
            root._failClosed("unknown-protocol");
        }
    }

    function status() {
        return {
            active: root.active,
            ready: root.ready,
            lastError: root._lastError,
            observerPath: root.observerPath
        };
    }

    Component.onDestruction: {
        observer.running = false;
    }
}
