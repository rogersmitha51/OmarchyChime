// Chime sound controller: settings persistence, playback gating, and the
// single pw-play voice for the Omarchy Chime plugin.
//
// The host (Service.qml) supplies the external gates:
//   - safetyReady: conservative session safety (unlocked, non-idle, no DND,
//     real screen, settled startup)
//   - desktopReady: the desktop adapter's readiness (host/compositor
//     monitoring safe and settled)
//   - systemReady: the system adapter's readiness (volume/power hardware
//     state safe and settled)
//   - overlapBlocked: another plugin owns the same sound role
//     (gobijan.ui-sounds enabled; unknown => true)
//   - notificationReady: the notification observer's readiness (bound by the
//     host to the observer's ready state; false until then)
//
// Settings live in a single versioned JSON file under
// $XDG_CONFIG_HOME/omarchy/chime.json (falling back to ~/.config). Missing
// files seed safe defaults; invalid content is never overwritten — the
// current settings are preserved and the error is reported truthfully.
// Readiness stays false until the initial settings decision is made.
//
// Automatic playback has three kinds. Desktop events (windowOpened,
// windowClosed, workspaceSwitched) are gated by desktop activation,
// ui-sounds overlap, and desktop readiness; system events (volumeUp,
// volumeDown, powerConnected, powerDisconnected) by the shared base policy
// plus the system adapter's readiness; the notification event
// (notificationReceived) is gated only by its own switch, session safety,
// and observer readiness — desktop activation/readiness and ui-sounds
// overlap never cut a notification cue. All kinds share the single voice
// and the master switch. The post-exit cooldown governs only notification
// playback and previews: automatic non-notification events ignore it
// entirely, because their source state machines already deduplicate
// non-transitions and the controller preempts while a voice is running.
// Cancellation is event-specific: desktop gate changes cut only desktop
// cues, the notifications switch and observer readiness loss cut only
// notification cues, while master mute and safety loss stop everything.
//
// Playback is a single voice with a synchronous reservation: `playing`
// becomes true the moment a play is accepted, before the child process is
// even requested, so same-tick bursts see one accepted play and then
// "busy". The reservation is only released when the child has actually
// exited (or failed to start); a cancellation that lands before the child
// was ever spawned releases it immediately so it can never strand.
//
// Rapid automatic non-notification events preempt one another: when an
// otherwise-eligible automatic event arrives while a different automatic
// non-notification cue owns the voice, the old cue is terminated and the
// new event is retained as a single latest-only pending replacement, which
// starts only after the old process has actually exited — never overlapping
// it. A further automatic event replaces the pending intent; a preview or a
// notification cue is never preempted (and never preempts).

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
    property bool systemReady: false
    property bool overlapBlocked: true
    property bool notificationReady: false

    readonly property string home: Quickshell.env("HOME")
    readonly property string xdgConfigHome: Quickshell.env("XDG_CONFIG_HOME")
    readonly property string configPath: (xdgConfigHome ? xdgConfigHome : home + "/.config") + "/omarchy/chime.json"

    // Exposed controller state.
    readonly property bool settingsReady: root._settingsReady
    override readonly property bool enabled: root._settings.enabled
    readonly property real volume: root._settings.volume
    readonly property bool desktopEnabled: root._settings.desktopEnabled
    readonly property bool notificationsEnabled: root._settings.notificationsEnabled
    readonly property bool playing: root._reserved || player.running

    // The notification cue is a local plugin asset. Resolved relative to this
    // file through Qt.resolvedUrl so playback never depends on the host
    // shell's working directory. pw-play receives the path as argv[1], so the
    // file:// prefix is removed here before decoding to a native path.
    readonly property string notificationAssetPath: {
        var url = Qt.resolvedUrl(ChimeLogic.NOTIFICATION_ASSET);
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
    // Post-exit cooldown state. Governs only notification playback and
    // previews; automatic non-notification events are exempt from it
    // entirely.
    property bool _cooldownActive: false
    property bool _destroyed: false
    property bool _deliberateStop: false
    // Set by a deliberate preemption (latest-only replacement) so the
    // release it causes is exempt from arming the cooldown — a deliberately
    // cut cue's exit is not a natural completion, and arming the cooldown
    // then would stall the notification cues and previews that still obey
    // it. Consumed by the release that clears it; an ordinary completion or
    // cancellation still arms the cooldown.
    property bool _skipCooldown: false
    // Synchronous playback claim. Set before the child is requested, cleared
    // only once the child has actually exited (or failed to start).
    property bool _reserved: false
    // Whether the child has actually started (Process.started fired). False
    // while the start is still pending (pre-post-reload) or has failed.
    property bool _childStarted: false
    // True while the current playback is a preview, so gate changes that only
    // affect automatic playback can leave previews alone.
    property bool _isPreview: false
    // Latest-only pending replacement: an automatic non-notification event
    // retained while a different automatic non-notification cue owns the
    // voice. It is started only after the old process has actually exited
    // (or failed to start), and its release is exempt from arming the
    // cooldown — a deliberately cut cue's exit must not stall the
    // notification cues and previews that still obey it. Cleared by any gate
    // loss, stop, or destruction so an inapplicable replacement never plays
    // late.
    property string _pendingReplacement: ""

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
            // The process ended on its own: any pending preemption intent is
            // inapplicable — the voice is not being released by the deliberate
            // replacement — so drop it. A deliberate preemption keeps
            // `_deliberateStop` set until this release, so its retained
            // replacement survives the exit and starts here.
            if (root._pendingReplacement !== "" && !root._deliberateStop)
                root._pendingReplacement = "";
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
    // an intentional stop, so mute/unmute cannot bypass it — except for a
    // release caused by a deliberate preemption (latest-only replacement),
    // which skips arming it so the cut cue's exit does not stall the
    // notification cues and previews that still obey the cooldown.
    // `failedToStart` reports the one failure mode that has no exited signal.
    function _releasePlayback(failedToStart) {
        var wasDeliberate = root._deliberateStop;
        var skipCooldown = root._skipCooldown;
        root._deliberateStop = false;
        root._skipCooldown = false;
        root._reserved = false;
        root._childStarted = false;
        root._currentEvent = "";
        if (failedToStart && !wasDeliberate)
            root._playbackError = "pw-play failed to start";
        if (!root._destroyed) {
            if (skipCooldown)
                cooldownTimer.stop();
            else
                root._armCooldown();
        }
        if (root._pendingReplacement !== "")
            root._startPendingReplacement();
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

    // Cancel playback of one automatic kind (desktop or notification). Gate
    // changes that only govern one kind — desktop activation, ui-sounds
    // overlap, and desktop/adapter readiness for desktop cues; the
    // notifications switch and observer readiness loss for notification
    // cues — must not cut the other kind, and never cut a preview. A pending
    // replacement of the affected kind is cleared too: it must not play late
    // once the gate that governs it has closed.
    function _stopKind(notificationKind) {
        if (root._isPreview)
            return;
        if (ChimeLogic.isNotificationEvent(root._currentEvent) === notificationKind)
            root._cancelPlayback();
        if (root._pendingReplacement !== "" && ChimeLogic.isNotificationEvent(root._pendingReplacement) === notificationKind) {
            // The deliberate replacement is cancelled: its release must arm
            // the normal cooldown instead of skipping it.
            root._pendingReplacement = "";
            root._skipCooldown = false;
        }
    }

    function _stopAutomatic() {
        root._stopKind(false);
    }

    function _stopNotifications() {
        root._stopKind(true);
    }

    // System adapter readiness loss cuts system (volume/power) cues and any
    // pending system replacement — never desktop cues, notification cues, or
    // a preview.
    function _stopSystem() {
        if (root._isPreview)
            return;
        if (ChimeLogic.isSystemEvent(root._currentEvent))
            root._cancelPlayback();
        if (root._pendingReplacement !== "" && ChimeLogic.isSystemEvent(root._pendingReplacement)) {
            // The deliberate replacement is cancelled: its release must arm
            // the normal cooldown instead of skipping it.
            root._pendingReplacement = "";
            root._skipCooldown = false;
        }
    }

    // Desktop adapter readiness loss cuts desktop (window/workspace) cues and
    // any pending desktop replacement — never system cues (which are gated
    // by systemReady), notification cues, or a preview.
    function _stopDesktop() {
        if (root._isPreview)
            return;
        if (!ChimeLogic.isSystemEvent(root._currentEvent) && !ChimeLogic.isNotificationEvent(root._currentEvent))
            root._cancelPlayback();
        if (root._pendingReplacement !== "" && !ChimeLogic.isSystemEvent(root._pendingReplacement) && !ChimeLogic.isNotificationEvent(root._pendingReplacement)) {
            // The deliberate replacement is cancelled: its release must arm
            // the normal cooldown instead of skipping it.
            root._pendingReplacement = "";
            root._skipCooldown = false;
        }
    }

    // Safety loss, explicit mute, stop, and unload stop everything — and
    // clear any pending replacement (also restoring the normal cooldown for
    // the release it would have caused), which must not play late once the
    // playback context is gone.
    function _stopAll() {
        root._pendingReplacement = "";
        root._skipCooldown = false;
        root._cancelPlayback();
    }

    function _play(asset, volume) {
        root._reserved = true;
        root._childStarted = false;
        player.command = ChimeLogic.playerCommand(asset, volume);
        player.running = true;
    }

    // Start the retained latest-only pending replacement. Runs synchronously
    // only once the voice is actually free, so a replacement never overlaps
    // the old process. Every gate is re-evaluated before the play is accepted
    // — the replacement is not entitled to play if the state has changed while
    // it was waiting.
    function _startPendingReplacement() {
        var eventName = root._pendingReplacement;
        root._pendingReplacement = "";
        var result = root._startAutomatic(eventName);
        if (result !== eventName && result !== "notificationReceived")
            root._playbackError = "";
    }

    // Gate-check an automatic non-notification event and, when eligible,
    // start it. Returns the event name when played, or the first blocking
    // reason. Events that are valid and otherwise eligible are never reported
    // "busy": while another automatic non-notification cue owns the voice
    // they preempt it (latest-only pending replacement); a preview or a
    // notification cue is never preempted, so those still report "busy". The
    // cooldown is deliberately not part of this gate state: automatic
    // non-notification events ignore the post-exit cooldown entirely — the
    // source state machines deduplicate non-transitions and the controller
    // preempts a running voice, so a rapid repeated event (e.g. a second
    // workspaceSwitched after the child exited) must stay eligible.
    // Notification playback and previews keep the cooldown as their own gate.
    function _startAutomatic(eventName) {
        var state = {
            settingsReady: root._settingsReady,
            enabled: root.enabled,
            desktopEnabled: root.desktopEnabled,
            overlapBlocked: root.overlapBlocked,
            safetyReady: root.safetyReady,
            desktopReady: root.desktopReady,
            systemReady: root.systemReady,
            eventReady: ChimeLogic.isSystemEvent(eventName) ? root.systemReady : root.desktopReady,
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

    // Play an automatic desktop or system event. Returns a short human-useful
    // string: the event name when played, the first blocking reason, or
    // "busy" when the voice is owned by a preview or a notification cue.
    function playEvent(eventName) {
        if (!ChimeLogic.isValidEvent(eventName))
            return "unknown event: " + eventName;
        if (ChimeLogic.isNotificationEvent(eventName))
            return root.playNotificationEvent();
        var reason = root._gatesBlocked(eventName);
        if (reason)
            return reason;
        var asset = ChimeLogic.assetPath(eventName);
        if (!asset)
            return "no asset for event: " + eventName;
        if (root.playing) {
            // A preview or a notification cue owns the voice: never preempted.
            // A different automatic non-notification cue is preemptible.
            if (root._isPreview || ChimeLogic.isNotificationEvent(root._currentEvent))
                return "busy";
            if (root._pendingReplacement !== "") {
                // A replacement is already pending from the same preemption:
                // keep only the latest event.
                root._pendingReplacement = eventName;
                return eventName;
            }
            root._pendingReplacement = eventName;
            root._deliberateStop = true;
            root._skipCooldown = true;
            root._cancelPlayback();
            return eventName;
        }
        if (root._pendingReplacement !== "") {
            // No process owns the voice but an intent is still pending from
            // the preemption release path (e.g. the previous child exited and
            // the replacement is waiting inside the same release): keep only
            // the latest event.
            root._pendingReplacement = eventName;
            return eventName;
        }
        return root._startAutomatic(eventName);
    }

    // First blocking reason for a valid non-notification automatic event,
    // from the shared gate policy. The kind-specific readiness gate is
    // selected here: system events (volume/power) use systemReady, everything
    // else uses desktopReady. The cooldown and the voice-busy gate are
    // deliberately excluded: the cooldown never governs automatic
    // non-notification events (the source state machines deduplicate
    // non-transitions, the controller preempts a running voice, and
    // notification playback and previews keep the cooldown as their own
    // gate), and ownership of the single voice is decided by this controller,
    // not by the shared policy — a free voice starts the event, a preview or
    // notification cue is never preempted ("busy"), and a different automatic
    // non-notification cue is preempted (latest-only replacement) once the
    // new event passes its own gates. The immediate-start path inside
    // `_startAutomatic` still enforces the held-claim gate.
    function _gatesBlocked(eventName) {
        return ChimeLogic.automaticBlockedReason({
            settingsReady: root._settingsReady,
            enabled: root.enabled,
            desktopEnabled: root.desktopEnabled,
            overlapBlocked: root.overlapBlocked,
            safetyReady: root.safetyReady,
            desktopReady: root.desktopReady,
            systemReady: root.systemReady,
            eventReady: ChimeLogic.isSystemEvent(eventName) ? root.systemReady : root.desktopReady,
            playing: false
        });
    }

    // Play the automatic notification cue. Gated by the master switch, the
    // per-event switch, session safety, observer readiness, and the post-exit
    // cooldown — never by desktop activation, ui-sounds overlap, or desktop
    // readiness. Shares the single voice with all other playback.
    function playNotificationEvent() {
        var state = {
            settingsReady: root._settingsReady,
            enabled: root.enabled,
            notificationsEnabled: root.notificationsEnabled,
            safetyReady: root.safetyReady,
            notificationReady: root.notificationReady,
            cooldownActive: root._cooldownActive,
            playing: root.playing
        };
        var reason = ChimeLogic.notificationBlockedReason(state);
        if (reason)
            return reason;
        var asset = root.notificationAssetPath;
        if (!asset)
            return "no asset for event: notificationReceived";
        root._playbackError = "";
        root._currentEvent = "notificationReceived";
        root._isPreview = false;
        root._play(asset, root.volume);
        return "notificationReceived";
    }

    // Preview an event. Ignores master mute, desktop activation, overlap and
    // desktop readiness, but never safetyReady. Still bounded by the single
    // voice and the post-exit cooldown.
    function preview(eventName) {
        if (!ChimeLogic.isValidEvent(eventName))
            return "unknown event: " + eventName;
        if (!root.safetyReady)
            return "not safe";
        if (root._cooldownActive)
            return "cooldown";
        if (root.playing)
            return "busy";
        var asset = ChimeLogic.isNotificationEvent(eventName) ? root.notificationAssetPath : ChimeLogic.assetPath(eventName);
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
        next.notificationsEnabled = partial.notificationsEnabled !== undefined ? partial.notificationsEnabled : root._settings.notificationsEnabled;
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

    function setNotificationsEnabled(value) {
        if (typeof value !== "boolean")
            return "invalid value";
        if (value === root.notificationsEnabled) {
            // Repeating the disable must still cut any playing notification cue.
            if (!value)
                root._stopNotifications();
            return root.notificationsEnabled ? "on" : "off";
        }
        root._replaceSettings({
            notificationsEnabled: value
        });
        root._persist();
        return root.notificationsEnabled ? "on" : "off";
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
            notificationsEnabled: root.notificationsEnabled,
            notificationReady: root.notificationReady,
            safetyReady: root.safetyReady,
            desktopReady: root.desktopReady,
            systemReady: root.systemReady,
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
    // cues; the notifications switch and observer readiness loss cut
    // notification cues. Safety loss and mute stop previews too; the
    // kind-specific gates leave previews and the other kind alone.
    onSafetyReadyChanged: if (!root.safetyReady)
        root._stopAll()
    onEnabledChanged: if (!root.enabled)
        root._stopAll()
    onDesktopEnabledChanged: if (!root.desktopEnabled)
        root._stopAutomatic()
    onOverlapBlockedChanged: if (root.overlapBlocked)
        root._stopAutomatic()
    onDesktopReadyChanged: if (!root.desktopReady)
        root._stopDesktop()
    onSystemReadyChanged: if (!root.systemReady)
        root._stopSystem()
    onNotificationsEnabledChanged: if (!root.notificationsEnabled)
        root._stopNotifications()
    onNotificationReadyChanged: if (!root.notificationReady)
        root._stopNotifications()

    Component.onDestruction: {
        root._destroyed = true;
        root._pendingReplacement = "";
        if (player.running)
            player.running = false;
    }
}
