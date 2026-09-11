// Chime sound controller: settings persistence, playback gating, and the
// single pw-play voice for the Omarchy Chime plugin.
//
// The host (Service.qml) supplies the external gates:
//   - safetyReady: conservative session safety (unlocked, non-idle, no DND,
//     real screen, settled startup)
//   - desktopReady: the desktop adapter's readiness (host/compositor
//     monitoring safe and settled)
//   - overlapBlocked: another plugin owns the same sound role
//     (gobijan.ui-sounds enabled; unknown => true)
//   - agentInputReady: the notification observer's readiness (bound by the
//     host to the observer's ready state; false until then)
//
// Settings live in a single versioned JSON file under
// $XDG_CONFIG_HOME/omarchy/chime.json (falling back to ~/.config). Missing
// files seed safe defaults; invalid content is never overwritten — the
// current settings are preserved and the error is reported truthfully.
// Readiness stays false until the initial settings decision is made.
//
// Automatic playback has two independent kinds. Desktop events
// (windowOpened, windowClosed, workspaceSwitched) are gated by desktop
// activation, ui-sounds overlap, and desktop readiness; the agent-input
// event (agentNeedsInput) is gated only by its own switch, session safety,
// and observer readiness — desktop activation/readiness and ui-sounds
// overlap never cut an agent cue. Both kinds share the single voice, the
// cooldown, and the master switch, and cancellation is event-specific:
// desktop gate changes cut only desktop cues, the agent-input switch and
// observer readiness loss cut only agent cues, while master mute and safety
// loss stop everything.
//
// Playback is a single voice with a synchronous reservation: `playing`
// becomes true the moment a play is accepted, before the child process is
// even requested, so same-tick bursts see one accepted play and then
// "busy". The reservation is only released when the child has actually
// exited (or failed to start); a cancellation that lands before the child
// was ever spawned releases it immediately so it can never strand.

import QtQuick
import Quickshell
import Quickshell.Io
import "ChimeLogic.js" as ChimeLogic

Item {
    id: root

    // External gates, supplied by the host. Defaults are conservative: not
    // safe, not ready, overlap unknown (blocked), observer not ready.
    property bool safetyReady: false
    property bool desktopReady: false
    property bool overlapBlocked: true
    property bool agentInputReady: false

    readonly property string home: Quickshell.env("HOME")
    readonly property string xdgConfigHome: Quickshell.env("XDG_CONFIG_HOME")
    readonly property string configPath: (xdgConfigHome ? xdgConfigHome : home + "/.config") + "/omarchy/chime.json"

    // Exposed controller state.
    readonly property bool settingsReady: root._settingsReady
    override readonly property bool enabled: root._settings.enabled
    readonly property real volume: root._settings.volume
    readonly property bool desktopEnabled: root._settings.desktopEnabled
    readonly property bool agentInputEnabled: root._settings.agentInputEnabled
    readonly property bool playing: root._reserved || player.running

    // The agent-input cue is a local plugin asset. Resolved relative to this
    // file through Qt.resolvedUrl so playback never depends on the host
    // shell's working directory. pw-play receives the path as argv[1], so the
    // file:// prefix is removed here before decoding to a native path.
    readonly property string agentAssetPath: {
        var url = Qt.resolvedUrl(ChimeLogic.AGENT_ASSET);
        if (!url)
            return "";
        var s = String(url);
        if (s.indexOf("file://") === 0)
            s = s.slice(7);
        return decodeURIComponent(s);
    }

    // Internal settings state. `_settings` is the last decided settings; it is
    // only replaced by a valid file or, before the first decision, by safe
    // defaults. `_settingsSource` records where the current settings came from
    // so status() can report it truthfully.
    property var _settings: ChimeLogic.defaults()
    property bool _settingsReady: false
    property string _settingsSource: ""
    property string _settingsError: ""
    property string _currentEvent: ""
    property string _playbackError: ""
    property bool _cooldownActive: false
    property bool _destroyed: false
    property bool _deliberateStop: false
    // Synchronous playback claim. Set before the child is requested, cleared
    // only once the child has actually exited (or failed to start).
    property bool _reserved: false
    // Whether the child has actually started (Process.started fired). False
    // while the start is still pending (pre-post-reload) or has failed.
    property bool _childStarted: false
    // True while the current playback is a preview, so gate changes that only
    // affect automatic playback can leave previews alone.
    property bool _isPreview: false

    // The single playback voice. `running = false` sends SIGTERM; the
    // destructor kills the child, so stopping and destruction both actually
    // stop the owned process (verified against Quickshell's process.cpp).
    Process {
        id: player
        onStarted: root._childStarted = true
        onRunningChanged: {
            if (root._destroyed)
                return;
            if (!player.running && root._reserved && !root._childStarted) {
                // FailedToStart drops the process without an exited signal; the
                // runningChanged(false) is the only notification. A successful exit
                // releases the reservation in onExited first, so it never reaches
                // here.
                root._releasePlayback(true);
            }
        }
    }

    Connections {
        target: player
        function onExited(exitCode) {
            if (root._destroyed)
                return;
            if (exitCode !== 0 && !root._deliberateStop)
                root._playbackError = "pw-play exited with code " + exitCode;
            root._releasePlayback(false);
        }
    }

    Timer {
        id: cooldownTimer
        interval: ChimeLogic.COOLDOWN_MS
        repeat: false
        onTriggered: root._cooldownActive = false
    }

    FileView {
        id: settingsFile
        path: root.configPath
        watchChanges: true
        printErrors: false
        onLoaded: root._applySettingsText(text())
        onLoadFailed: function (error) {
            // A missing file is the normal first-run case: seed safe defaults
            // without an error. Any other failure is reported truthfully and the
            // current settings are preserved.
            if (error === FileViewError.FileNotFound) {
                root._decideSettings({
                    ok: false,
                    error: ""
                });
            } else {
                root._decideSettings({
                    ok: false,
                    error: "settings load failed: " + FileViewError.toString(error)
                });
            }
        }
        onFileChanged: reload()
        onSaved: {
            root._settingsError = "";
            root._settingsSource = "file";
        }
        onSaveFailed: function (error) {
            root._settingsError = "settings save failed: " + FileViewError.toString(error);
        }
    }

    function _decideSettings(result) {
        var decision = ChimeLogic.decideSettings({
            settingsReady: root._settingsReady,
            settings: root._settings
        }, result);
        root._settings = decision.settings;
        root._settingsSource = decision.source;
        root._settingsError = decision.error;
        root._settingsReady = true;
    }

    function _applySettingsText(text) {
        root._decideSettings(ChimeLogic.parseSettings(text));
    }

    function _armCooldown() {
        root._cooldownActive = true;
        cooldownTimer.restart();
    }

    // Release the playback claim. Always arms the cooldown, including after
    // an intentional stop, so mute/unmute cannot bypass it. `failedToStart`
    // reports the one failure mode that has no exited signal.
    function _releasePlayback(failedToStart) {
        var wasDeliberate = root._deliberateStop;
        root._deliberateStop = false;
        root._reserved = false;
        root._childStarted = false;
        root._currentEvent = "";
        if (failedToStart && !wasDeliberate)
            root._playbackError = "pw-play failed to start";
        if (!root._destroyed)
            root._armCooldown();
    }

    // Cancel the current playback. If the child is running it is terminated
    // and the reservation is released when it actually exits; if the start is
    // still pending (no child spawned yet, e.g. before the shell's post-reload
    // hook) the reservation is released immediately — no exit signal will
    // ever arrive for a child that was never spawned. `running = false` also
    // clears the C++ pending-start flag, so the post-reload hook cannot spawn
    // the cancelled child later.
    function _cancelPlayback() {
        if (!root._reserved)
            return;
        root._deliberateStop = true;
        if (player.running) {
            player.running = false;
        } else if (!root._childStarted) {
            player.running = false;
            root._releasePlayback(false);
        }
    }

    // Cancel playback of one automatic kind (desktop or agent-input). Gate
    // changes that only govern one kind — desktop activation, ui-sounds
    // overlap, and desktop readiness for desktop cues; the agent-input switch
    // and observer readiness loss for agent cues — must not cut the other
    // kind, and never cut a preview.
    function _stopKind(agentKind) {
        if (root._isPreview)
            return;
        if (ChimeLogic.isAgentEvent(root._currentEvent) === agentKind)
            root._cancelPlayback();
    }

    function _stopAutomatic() {
        root._stopKind(false);
    }

    function _stopAgentInput() {
        root._stopKind(true);
    }

    // Safety loss, explicit mute, stop, and unload stop everything.
    function _stopAll() {
        root._cancelPlayback();
    }

    function _play(asset, volume) {
        root._reserved = true;
        root._childStarted = false;
        player.command = ChimeLogic.playerCommand(asset, volume);
        player.running = true;
    }

    // Play an automatic desktop event. Returns a short human-useful string:
    // the event name when played, or the first blocking reason.
    function playEvent(eventName) {
        if (!ChimeLogic.isValidEvent(eventName))
            return "unknown event: " + eventName;
        if (ChimeLogic.isAgentEvent(eventName))
            return root.playAgentInputEvent();
        var state = {
            settingsReady: root._settingsReady,
            enabled: root.enabled,
            desktopEnabled: root.desktopEnabled,
            overlapBlocked: root.overlapBlocked,
            safetyReady: root.safetyReady,
            desktopReady: root.desktopReady,
            cooldownActive: root._cooldownActive,
            playing: root.playing
        };
        var reason = ChimeLogic.automaticBlockedReason(state);
        if (reason)
            return reason;
        var asset = ChimeLogic.assetPath(eventName);
        if (!asset)
            return "no asset for event: " + eventName;
        root._playbackError = "";
        root._currentEvent = eventName;
        root._isPreview = false;
        root._play(asset, root.volume);
        return eventName;
    }

    // Play the automatic agent-input cue. Gated by the master switch, the
    // per-event switch, session safety, and observer readiness — never by
    // desktop activation, ui-sounds overlap, or desktop readiness. Shares the
    // single voice and the cooldown with desktop playback.
    function playAgentInputEvent() {
        var state = {
            settingsReady: root._settingsReady,
            enabled: root.enabled,
            agentInputEnabled: root.agentInputEnabled,
            safetyReady: root.safetyReady,
            agentInputReady: root.agentInputReady,
            cooldownActive: root._cooldownActive,
            playing: root.playing
        };
        var reason = ChimeLogic.agentInputBlockedReason(state);
        if (reason)
            return reason;
        var asset = root.agentAssetPath;
        if (!asset)
            return "no asset for event: agentNeedsInput";
        root._playbackError = "";
        root._currentEvent = "agentNeedsInput";
        root._isPreview = false;
        root._play(asset, root.volume);
        return "agentNeedsInput";
    }

    // Preview an event. Ignores master mute, desktop activation, overlap and
    // desktop readiness, but never safetyReady. Still bounded by the single
    // voice and the cooldown.
    function preview(eventName) {
        if (!ChimeLogic.isValidEvent(eventName))
            return "unknown event: " + eventName;
        if (!root.safetyReady)
            return "not safe";
        if (root._cooldownActive)
            return "cooldown";
        if (root.playing)
            return "busy";
        var asset = ChimeLogic.isAgentEvent(eventName) ? root.agentAssetPath : ChimeLogic.assetPath(eventName);
        if (!asset)
            return "no asset for event: " + eventName;
        root._playbackError = "";
        root._currentEvent = eventName;
        root._isPreview = true;
        root._play(asset, root.volume);
        return eventName;
    }

    function _replaceSettings(partial) {
        var next = ChimeLogic.defaults();
        next.enabled = partial.enabled !== undefined ? partial.enabled : root._settings.enabled;
        next.volume = partial.volume !== undefined ? partial.volume : root._settings.volume;
        next.desktopEnabled = partial.desktopEnabled !== undefined ? partial.desktopEnabled : root._settings.desktopEnabled;
        next.agentInputEnabled = partial.agentInputEnabled !== undefined ? partial.agentInputEnabled : root._settings.agentInputEnabled;
        root._settings = next;
    }

    function setEnabled(value) {
        if (typeof value !== "boolean")
            return "invalid value";
        if (value === root.enabled) {
            // Repeating the mute must still cut any playing preview short.
            if (!value)
                root._stopAll();
            return root.enabled ? "on" : "off";
        }
        root._replaceSettings({
            enabled: value
        });
        root._persist();
        return root.enabled ? "on" : "off";
    }

    function setVolume(value) {
        if (typeof value !== "number" || !isFinite(value) || value < 0 || value > 1)
            return "invalid volume";
        if (value === root.volume)
            return String(value);
        root._replaceSettings({
            volume: value
        });
        root._persist();
        return String(root.volume);
    }

    function setDesktopEnabled(value) {
        if (typeof value !== "boolean")
            return "invalid value";
        if (value === root.desktopEnabled) {
            if (!value)
                root._stopAutomatic();
            return root.desktopEnabled ? "on" : "off";
        }
        root._replaceSettings({
            desktopEnabled: value
        });
        root._persist();
        return root.desktopEnabled ? "on" : "off";
    }

    function setAgentInputEnabled(value) {
        if (typeof value !== "boolean")
            return "invalid value";
        if (value === root.agentInputEnabled) {
            // Repeating the disable must still cut any playing agent-input cue.
            if (!value)
                root._stopAgentInput();
            return root.agentInputEnabled ? "on" : "off";
        }
        root._replaceSettings({
            agentInputEnabled: value
        });
        root._persist();
        return root.agentInputEnabled ? "on" : "off";
    }

    function _persist() {
        // Never write before the initial settings decision: a pre-load setter
        // must not overwrite the on-disk settings with defaults plus one change.
        if (!root._settingsReady)
            return;
        settingsFile.setText(ChimeLogic.serializeSettings(root._settings));
    }

    // JSON-serializable status object: settings state, gates, current event,
    // and any playback failure. No raw telemetry.
    function status() {
        return {
            settingsReady: root._settingsReady,
            settingsSource: root._settingsSource,
            settingsError: root._settingsError,
            enabled: root.enabled,
            volume: root.volume,
            desktopEnabled: root.desktopEnabled,
            agentInputEnabled: root.agentInputEnabled,
            agentInputReady: root.agentInputReady,
            safetyReady: root.safetyReady,
            desktopReady: root.desktopReady,
            overlapBlocked: root.overlapBlocked,
            playing: root.playing,
            currentEvent: root._currentEvent,
            cooldownActive: root._cooldownActive,
            playbackError: root._playbackError,
            configPath: root.configPath
        };
    }

    function stop() {
        root._stopAll();
        return "stopped";
    }

    // Automatic playback must stop the moment a gate for its kind closes:
    // desktop deactivation, overlap, or desktop readiness loss cut desktop
    // cues; the agent-input switch and observer readiness loss cut agent
    // cues. Safety loss and mute stop previews too; the kind-specific gates
    // leave previews and the other kind alone.
    onSafetyReadyChanged: if (!root.safetyReady)
        root._stopAll()
    onEnabledChanged: if (!root.enabled)
        root._stopAll()
    onDesktopEnabledChanged: if (!root.desktopEnabled)
        root._stopAutomatic()
    onOverlapBlockedChanged: if (root.overlapBlocked)
        root._stopAutomatic()
    onDesktopReadyChanged: if (!root.desktopReady)
        root._stopAutomatic()
    onAgentInputEnabledChanged: if (!root.agentInputEnabled)
        root._stopAgentInput()
    onAgentInputReadyChanged: if (!root.agentInputReady)
        root._stopAgentInput()

    Component.onDestruction: {
        root._destroyed = true;
        if (player.running)
            player.running = false;
    }
}
