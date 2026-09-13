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
// Each event's cue is a catalog sound id under the v4 settings' `sounds`
// map (issue #7): assigned through setEventSound (panel or IPC), persisted
// with the rest of the schema, and resolved at play time — a stale id
// fails safe to the event's default cue.
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
// Rapid automatic non-notification events preempt one another through a
// single latest-only pending replacement. Repeated volume events in the same
// direction are coalesced so a tonal cue can finish cleanly; reversing
// direction preempts it so the audible cue immediately reflects the user's
// latest input. A preview or notification cue is never preempted (and never
// preempts), and replacements start only after the old child exits.
// Playback is a single voice with a synchronous reservation: `playing`
// becomes true the moment a play is accepted, before the child process is
// even requested. The reservation is released only when the child exits (or
// fails to start), so replacements never overlap.

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
    readonly property var eventSounds: root._settings.sounds
    readonly property var soundCatalog: ChimeLogic.SOUND_CATALOG
    readonly property var soundIds: ChimeLogic.SOUND_IDS
    readonly property string soundNoneId: ChimeLogic.SOUND_NONE
    readonly property var themePackIds: ChimeLogic.THEME_PACK_IDS
    readonly property var themePackLabels: ChimeLogic.THEME_PACK_LABELS
    readonly property string themePackCustomId: ChimeLogic.THEME_PACK_CUSTOM
    readonly property string themePack: ChimeLogic.themePackId(root._settings.sounds)
    readonly property bool playing: root._reserved || player.running

    // The catalog id assigned to an event (with event-default fallback for
    // a missing or stale assignment; "none" passes through). The panel
    // reads this for each dropdown's current value.
    function eventSoundId(eventName) {
        return ChimeLogic.eventSoundId(eventName, root._settings.sounds);
    }

    // The human-readable event name for UI display (issue #9), e.g.
    // "windowOpened" -> "Window Opened". Presentation only: the ids the
    // panel sends back (setEventSound, preview) and the IPC surface stay
    // camelCase.
    function eventLabel(eventName) {
        return ChimeLogic.eventLabel(eventName);
    }

    // A complete pack assignment is applied in one settings write. Any later
    // per-event edit makes the derived themePack property read "custom".
    function setThemePack(packId) {
        if (!ChimeLogic.isValidThemePack(packId))
            return "unknown theme pack: " + packId;
        root._replaceSettings({
            sounds: ChimeLogic.themePackSounds(packId)
        });
        root._persist();
        return "theme pack -> " + packId;
    }

    // Resolves a relative asset (the plugin-local cue) through Qt.resolvedUrl
    // so playback never depends on the host shell's working directory;
    // absolute theme paths pass through. pw-play receives the path as
    // argv[1], so the file:// prefix is removed before decoding.
    function _resolvedAssetPath(path) {
        if (!path || path.indexOf("/") === 0)
            return path ? path : "";
        var url = Qt.resolvedUrl(path);
        if (!url)
            return "";
        var s = String(url);
        if (s.indexOf("file://") === 0)
            s = s.slice(7);
        return decodeURIComponent(s);
    }

    // The playable path for an event under the decided settings: the
    // assigned catalog sound, falling back to the event default. Theme
    // entries pass through; the relative local asset is resolved.
    function _eventAssetPath(eventName) {
        var path = ChimeLogic.eventSoundPath(eventName, root._settings.sounds);
        if (!path)
            return "";
        return root._resolvedAssetPath(path);
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
    // Latest-only pending preview (issue #7 panel behavior): an event whose
    // preview was requested while a preview already owned the voice — the
    // previous preview is cut (deliberately, cooldown-exempt) and this one
    // starts when the voice actually frees. Cleared by any gate loss, stop,
    // or destruction so a stale preview never plays late. Unlike
    // _pendingReplacement it starts through preview()'s gates (safety +
    // cooldown, ignoring mute), so the start path re-validates everything.
    property string _pendingPreview: ""

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
            if (exitCode !== 0 && !root._deliberateStop)
                root._playbackError = "pw-play exited with code " + exitCode;
            // The process ended on its own: any pending preemption intent is
            // inapplicable — the voice is not being released by the deliberate
            // replacement — so drop it. A deliberate preemption keeps
            // `_deliberateStop` set until this release, so its retained
            // replacement survives the exit and starts here. A pending
            // preview is likewise only retained across a deliberate cut of a
            // preview; a natural preview completion invalidates it.
            if (root._pendingPreview !== "" && !root._deliberateStop)
                root._pendingPreview = "";
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
        else if (root._pendingPreview !== "")
            root._startPendingPreview();
    }

    // Start the retained latest-only pending preview (issue #7 panel
    // behavior). Runs only once the voice is actually free, and re-runs
    // preview()'s own gates — safety, cooldown, asset — so the retained
    // intent is never entitled to play if the state has changed while it
    // waited. Deliberately ignores master mute, like any preview.
    function _startPendingPreview() {
        var eventName = root._pendingPreview;
        root._pendingPreview = "";
        root.preview(eventName);
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
    // clear any pending replacement or pending preview (also restoring the
    // normal cooldown for the release it would have caused), which must not
    // play late once the playback context is gone.
    function _stopAll() {
        root._pendingReplacement = "";
        root._pendingPreview = "";
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
    // reason. Events that are valid and otherwise eligible normally preempt
    // another automatic cue (latest-only pending replacement). Repeated volume
    // events in the same direction are coalesced to let the tonal cue finish;
    // a direction reversal preempts it so feedback follows the latest input.
    // A preview or notification cue is never preempted and reports "busy".
    // Automatic non-notification events ignore the post-exit cooldown because
    // their source state machines already deduplicate non-transitions.
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
        var asset = root._eventAssetPath(eventName);
        if (asset === "" && ChimeLogic.eventSoundId(eventName, root._settings.sounds) === ChimeLogic.SOUND_NONE)
            return "silent (" + eventName + " -> none)";
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
        if (ChimeLogic.eventSoundId(eventName, root._settings.sounds) === ChimeLogic.SOUND_NONE)
            return "silent (" + eventName + " -> none)";
        var asset = root._eventAssetPath(eventName);
        if (!asset)
            return "no asset for event: " + eventName;
        if (root.playing) {
            // Volume keys commonly emit faster than a short cue completes.
            // Coalesce repeats in the same direction so pw-play reaches the
            // file's zero-valued tail. A direction reversal remains
            // preemptible: keeping the old-direction cue is stale feedback.
            if (!root._isPreview
                    && root._currentEvent === eventName
                    && ChimeLogic.isVolumeEvent(eventName))
                return eventName;
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
    // selected here: system events use systemReady, everything else uses
    // desktopReady. Cooldown and voice ownership are deliberately excluded:
    // playEvent owns preemption/coalescing, while this helper only evaluates
    // the external gates. Notification playback and previews keep cooldown.
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
        var asset = root._eventAssetPath("notificationReceived");
        if (asset === "" && ChimeLogic.eventSoundId("notificationReceived", root._settings.sounds) === ChimeLogic.SOUND_NONE)
            return "silent (notificationReceived -> none)";
        if (!asset)
            return "no asset for event: notificationReceived";
        root._playbackError = "";
        root._currentEvent = "notificationReceived";
        root._isPreview = false;
        root._play(asset, root.volume);
        return "notificationReceived";
    }

    // Preview an event. Ignores master mute, desktop activation, overlap and
    // desktop readiness, but never safetyReady. Bounded by the single voice
    // and the post-exit cooldown — except against another preview: choosing
    // the next sound in the panel (issue #7) must interrupt the previous
    // preview, so a preview arriving while a preview owns the voice cuts it
    // deliberately (cooldown-exempt) and is retained as a single
    // latest-only pending intent that starts when the voice actually frees.
    // A preview never preempts an automatic cue or a notification cue —
    // those still report "busy" — and a retained intent re-runs preview()'s
    // gates before starting, so it is never entitled to play if safety or
    // the cooldown state has changed while it waited.
    function preview(eventName) {
        if (!ChimeLogic.isValidEvent(eventName))
            return "unknown event: " + eventName;
        if (!root.safetyReady)
            return "not safe";
        if (root.playing) {
            if (root._isPreview) {
                // A preview owns the voice: keep only the latest intent and
                // cut the running preview. The cut's release must not arm
                // the cooldown, or the replacement could never start.
                root._pendingPreview = eventName;
                if (root._pendingReplacement !== "")
                    return "busy"; // never preempt an automatic replacement's voice
                root._deliberateStop = true;
                root._skipCooldown = true;
                root._cancelPlayback();
                return eventName;
            }
            return "busy";
        }
        if (root._cooldownActive)
            return "cooldown";
        if (root._pendingPreview !== "") {
            // No process owns the voice but a retained preview intent is
            // still waiting inside the release path: keep only the latest.
            root._pendingPreview = eventName;
            return eventName;
        }
        var asset = root._eventAssetPath(eventName);
        if (asset === "" && ChimeLogic.eventSoundId(eventName, root._settings.sounds) === ChimeLogic.SOUND_NONE)
            return "silent (" + eventName + " -> none)";
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
        next.sounds = partial.sounds !== undefined ? partial.sounds : root._settings.sounds;
        root._settings = next;
    }

    // Assign a catalog sound to an event (issue #7). The event must be known
    // and the sound id must be in the catalog — a raw path can never enter
    // the settings through this API. Returns a short human-useful string:
    // "<event> -> <soundId>" on success, else the reason.
    function setEventSound(eventName, soundId) {
        if (!ChimeLogic.isValidEvent(eventName))
            return "unknown event: " + eventName;
        if (!ChimeLogic.isValidSound(soundId))
            return "unknown sound: " + soundId;
        var next = {};
        for (var id in root._settings.sounds)
            next[id] = root._settings.sounds[id];
        next[eventName] = soundId;
        root._replaceSettings({
            sounds: next
        });
        root._persist();
        return eventName + " -> " + soundId;
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
            eventSounds: root.eventSounds,
            themePack: root.themePack,
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
    onSystemReadyChanged: if (!root.systemReady)
        root._stopSystem()
    onNotificationsEnabledChanged: if (!root.notificationsEnabled)
        root._stopNotifications()
    onNotificationReadyChanged: if (!root.notificationReady)
        root._stopNotifications()

    Component.onDestruction: {
        root._destroyed = true;
        root._pendingReplacement = "";
        root._pendingPreview = "";
        if (player.running)
            player.running = false;
    }
}
