// Omarchy Chime settings panel. Binds the controller's live truth, offers
// per-event sound selection from the catalog (issue #7) with an audible
// preview on each choice, and reactive diagnostics. Lifecycle follows the
// shell panel contract (open/close flip the FloatingWindow, user close
// reports via shell.hide). One flat cursor: 3 toggles, volume slider, and
// 8 event sound dropdowns; Tab/j/k traverse, h/l adjusts volume,
// Enter/Space activate, Esc closes, hover shares it.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Ui
import qs.Commons

Item {
    id: root

    // Injected by omarchy-shell (the first-party panel loader).
    property var shell: null
    property var service: null
    property var manifest: null
    property var pluginRegistry: null
    property string omarchyPath: ""

    // The controller is injected through the service composition root;
    // Service.qml exposes it as the `controllerApi` alias. All binds read
    // its truth directly; all writes are gated on settingsReady. ctlStatus
    // is the controller's own status() snapshot; the binding captures the
    // status() internal property reads, so the snapshot re-evaluates
    // reactively whenever any of them change.
    readonly property var ctl: service && service.controllerApi ? service.controllerApi : null
    readonly property var ctlStatus: root.ctl ? root.ctl.status() : null

    // Single gate for every settings write: toggles and the volume slider are
    // interactive and full-opacity only once the controller's store is ready.
    // Controller-bound values below stay live regardless, so the panel always
    // shows the controller's truth even while it is loading.
    readonly property bool settingsWritable: root.ctl && root.ctl.settingsReady

    // ---- lifecycle -------------------------------------------------------

    property bool closingFromHost: false

    readonly property bool opened: window.visible

    function open(payloadJson) {
        root.closingFromHost = false;
        window.visible = true;
        // Defer focus so the FloatingWindow's content tree is mounted; the
        // cursor starts hidden until the first key or mouse entry.
        Qt.callLater(function () {
            root.cursorActive = false;
            if (keyCatcher)
                keyCatcher.forceActiveFocus();
        });
    }

    // Host-initiated close (shell hide). Visibility flips without notifying
    // the host back — it already knows.
    function close() {
        root.closingFromHost = true;
        window.visible = false;
        root.closingFromHost = false;
    }

    // User-initiated close (Esc, window close button). Tell the shell so its
    // openPanelIds map stays consistent and toggle works next time.
    function requestClose() {
        if (root.shell && typeof root.shell.hide === "function")
            root.shell.hide("nick.chime");
        else
            window.visible = false;
    }

    // ---- theme -----------------------------------------------------------

    readonly property color foreground: Color.foreground
    readonly property color background: Color.background
    readonly property color accent: Color.accent
    readonly property color urgent: Color.urgent
    readonly property string fontFamily: "monospace"

    // Fake `bar` for PanelSlider, matching the gallery recipe.
    readonly property var fakeBar: QtObject {
        readonly property color foreground: root.foreground
        readonly property color background: root.background
        readonly property color urgent: root.urgent
        readonly property string fontFamily: root.fontFamily
        readonly property string position: "top"
        readonly property bool vertical: false
        readonly property int barSize: 26
    }

    // One cursor over 12 targets: 0..2 toggles, 3 volume, 4..11 event sound
    // dropdowns.
    property bool cursorActive: false
    property int selectedIndex: 0

    readonly property var eventIds: ["windowOpened", "windowClosed", "workspaceSwitched", "notificationReceived", "volumeUp", "volumeDown", "powerConnected", "powerDisconnected"]

    readonly property int targetCount: 12
    readonly property int sliderIndex: 3
    readonly property int soundStart: 4
    // Mouse hover and keyboard share one cursor; select() is the single
    // write point and clamps in bounds.
    function select(index) {
        root.cursorActive = true;
        var next = Math.max(0, Math.min(root.targetCount - 1, index));
        root.selectedIndex = next;
    }

    function moveCursor(delta) {
        root.select(root.selectedIndex + delta);
    }

    // Scroll the target fully visible inside the viewport, 12px margin.
    // ScrollView.contentItem is a Flickable at runtime; Qt's static type data
    // exposes only QQuickItem here.
    // qmllint disable missing-property
    function ensureCursorVisible(item) {
        if (!item || !scrollArea)
            return;
        var flick = scrollArea.contentItem;
        if (!flick || flick.contentY === undefined)
            return;
        var pt = item.mapToItem(flick.contentItem || flick, 0, 0);
        var top = pt.y;
        var bottom = top + (item.height || 0);
        var viewTop = flick.contentY;
        var viewBottom = viewTop + flick.height;
        var margin = 12;
        if (top < viewTop + margin)
            flick.contentY = Math.max(0, top - margin);
        else if (bottom > viewBottom - margin)
            flick.contentY = bottom + margin - flick.height;
    }
    // qmllint enable missing-property

    // ---- actions ---------------------------------------------------------

    function activateCursor() {
        if (root.selectedIndex < root.sliderIndex) {
            // Toggle rows (0..2): activation flips the switch.
            if (root.selectedIndex === 0)
                root.flipEnabled();
            else if (root.selectedIndex === 1)
                root.flipDesktop();
            else if (root.selectedIndex === 2)
                root.flipNotifications();
            return;
        }
        // Volume slider (3) and event sound dropdowns (4..11): activation
        // is a no-op — the dropdowns open their popup directly.
    }
    // Options for one event's sound dropdown: the whole catalog, labels
    // shown, ids emitted. Rebuilt per row from the controller's catalog.
    function soundOptions() {
        var ctl = root.ctl;
        if (!ctl || !ctl.soundIds)
            return [];
        var out = [];
        for (var i = 0; i < ctl.soundIds.length; i++) {
            var id = ctl.soundIds[i];
            var entry = ctl.soundCatalog[id];
            out.push({
                value: id,
                label: entry ? entry.label : id
            });
        }
        return out;
    }

    // The catalog id currently assigned to an event, shown as the
    // dropdown's current value. The controller's eventSoundId() already
    // falls back to the event default for a missing/stale assignment and
    // passes "none" through — use it directly instead of duplicating the
    // default map here.
    function eventSoundId(eventName) {
        var ctl = root.ctl;
        if (!ctl || typeof ctl.eventSoundId !== "function")
            return "";
        return ctl.eventSoundId(eventName);
    }

    // Assign a catalog sound to an event; the controller validates and
    // persists. The result is shown in this section, and the newly assigned
    // cue is previewed immediately so choosing a sound is audible feedback,
    // not a blind write — unless the choice is "none", which is silence and
    // previews nothing.
    function setEventSound(eventName, soundId) {
        if (!root.ctl || !root.ctl.settingsReady)
            return;
        var result = root.ctl.setEventSound(eventName, soundId);
        if (result !== eventName + " -> " + soundId) {
            root.previewResult = result;
            return;
        }
        root.previewResult = root.ctl.eventLabel(eventName) + " -> " + soundId;
        if (soundId === "none")
            return;
        var preview = root.ctl.preview(eventName);
        root.previewResult = preview === eventName ? root.ctl.eventLabel(eventName) : preview;
    }

    function flipEnabled() {
        if (root.ctl && root.ctl.settingsReady)
            root.ctl.setEnabled(!root.ctl.enabled);
    }

    function flipDesktop() {
        if (root.ctl && root.ctl.settingsReady)
            root.ctl.setDesktopEnabled(!root.ctl.desktopEnabled);
    }

    function flipNotifications() {
        if (root.ctl && root.ctl.settingsReady)
            root.ctl.setNotificationsEnabled(!root.ctl.notificationsEnabled);
    }

    // h/l on the slider row: clamped 0.05 volume adjustment (write gated by
    // settingsReady like every other write).
    function adjustVolume(delta) {
        if (!root.ctl || !root.ctl.settingsReady)
            return;
        var next = Math.max(0, Math.min(1, root.ctl.volume + delta));
        root.ctl.setVolume(next);
    }

    // Most recent event-sound assignment or preview result.
    property string previewResult: ""

    // ---- window ----------------------------------------------------------

    FloatingWindow {
        id: window
        title: "Omarchy Chime — settings"
        color: root.background
        implicitWidth: 560
        implicitHeight: 640
        minimumSize: Qt.size(420, 420)

        onVisibleChanged: {
            if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
                root.shell.hide("nick.chime");
        }

        FocusScope {
            id: focusScope
            anchors.fill: parent
            focus: true

            PanelKeyCatcher {
                id: keyCatcher
                anchors.fill: parent

                // An open event-sound dropdown owns the keys (search field +
                // result list): all keys forward to it, none drive the cursor.
                blocked: soundGrid.popupOpen

                onMoveRequested: function (dx, dy) {
                    if (dy !== 0) {
                        root.moveCursor(dy);
                    } else if (dx !== 0) {
                        // h/l are local: adjust volume on the slider row only.
                        if (root.selectedIndex === root.sliderIndex)
                            root.adjustVolume(dx > 0 ? 0.05 : -0.05);
                    }
                }
                onTabRequested: function (direction) {
                    root.moveCursor(direction);
                }
                onActivateRequested: root.activateCursor()
                onCloseRequested: root.requestClose()

                ScrollView {
                    id: scrollArea
                    anchors.fill: parent
                    anchors.margins: Style.space(18)
                    clip: true
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                    Column {
                        width: scrollArea.availableWidth
                        spacing: Style.space(16)

                        // ---- header ---------------------------------------
                        PanelHero {
                            width: parent.width
                            title: "Omarchy Chime"
                            meta: "Desktop event sounds, system volume/power cues, and notification cues. Tab or j/k to walk, h/l on the volume row to adjust, Enter to activate, Esc to close."
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            detail: root.ctlStatus ? (root.ctlStatus.settingsReady ? "" : "loading…") : ""
                        }

                        PanelSeparator {
                            foreground: root.foreground
                        }

                        // ---- playback switches ------------------------------
                        Column {
                            width: parent.width
                            spacing: Style.space(8)

                            PanelSectionHeader {
                                width: parent.width
                                text: "Playback"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Toggle {
                                width: parent.width
                                label: "Sounds"
                                description: "Master switch: all chime playback."
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                checked: root.ctl ? root.ctl.enabled : false
                                enabled: root.settingsWritable
                                opacity: root.settingsWritable ? 1.0 : 0.5
                                hasCursor: root.cursorActive && root.selectedIndex === 0
                                onHovered: function (h) {
                                    if (h)
                                        root.select(0);
                                }
                                onHasCursorChanged: if (hasCursor)
                                    root.ensureCursorVisible(this)
                                onClicked: {
                                    root.select(0);
                                    root.flipEnabled();
                                }
                            }

                            Toggle {
                                width: parent.width
                                label: "Desktop sounds"
                                description: "Window and workspace cues: Window Opened, Window Closed, Workspace Switched."
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                checked: root.ctl ? root.ctl.desktopEnabled : false
                                enabled: root.settingsWritable
                                opacity: root.settingsWritable ? 1.0 : 0.5
                                hasCursor: root.cursorActive && root.selectedIndex === 1
                                onHovered: function (h) {
                                    if (h)
                                        root.select(1);
                                }
                                onHasCursorChanged: if (hasCursor)
                                    root.ensureCursorVisible(this)
                                onClicked: {
                                    root.select(1);
                                    root.flipDesktop();
                                }
                            }

                            Toggle {
                                width: parent.width
                                label: "Notification sounds"
                                description: "The notification cue (Notification Received)."
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                checked: root.ctl ? root.ctl.notificationsEnabled : false
                                enabled: root.settingsWritable
                                opacity: root.settingsWritable ? 1.0 : 0.5
                                hasCursor: root.cursorActive && root.selectedIndex === 2
                                onHovered: function (h) {
                                    if (h)
                                        root.select(2);
                                }
                                onHasCursorChanged: if (hasCursor)
                                    root.ensureCursorVisible(this)
                                onClicked: {
                                    root.select(2);
                                    root.flipNotifications();
                                }
                            }
                        }

                        // ---- volume ----------------------------------------
                        CursorSurface {
                            id: volumeRow
                            width: parent.width
                            implicitHeight: volumeRowContent.implicitHeight + Style.space(12) * 2
                            outline: true
                            foreground: root.foreground
                            opacity: root.settingsWritable ? 1.0 : 0.5
                            hasCursor: root.cursorActive && root.selectedIndex === root.sliderIndex
                            onHasCursorChanged: if (hasCursor)
                                root.ensureCursorVisible(this)

                            HoverHandler {
                                onHoveredChanged: if (hovered)
                                    root.select(root.sliderIndex)
                            }

                            Row {
                                id: volumeRowContent
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Style.space(14)
                                anchors.rightMargin: Style.space(14)
                                spacing: Style.space(10)

                                Text {
                                    textFormat: Text.PlainText
                                    text: "Chime/alert volume"
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.fontPx(1.0)
                                    width: 130
                                    elide: Text.ElideRight
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                // Controller truth drives the position; dragging
                                // only moves the local live value (display-only)
                                // and the release commits a single setVolume.
                                // While settings are loading the slider is muted:
                                // it cannot be grabbed or wheeled, so no drag can
                                // start, while the bound value still tracks the
                                // controller's truth.
                                PanelSlider {
                                    id: volumeSlider
                                    bar: root.fakeBar
                                    width: parent.width - 130 - 46 - parent.spacing * 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    value: root.ctl ? root.ctl.volume : 0
                                    enabled: root.settingsWritable
                                    onMoved: function (v) { /* display-only */ }
                                    onReleased: function (v) {
                                        if (root.ctl && root.ctl.settingsReady)
                                            root.ctl.setVolume(v);
                                    }
                                }

                                Text {
                                    textFormat: Text.PlainText
                                    text: Math.round((volumeSlider.dragging ? volumeSlider.liveValue : (root.ctl ? root.ctl.volume : 0)) * 100) + "%"
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.fontPx(1.0)
                                    width: 46
                                    horizontalAlignment: Text.AlignRight
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }

                        PanelSeparator {
                            foreground: root.foreground
                        }

                        // ---- event sounds (issue #7) -----------------------
                        Column {
                            width: parent.width
                            spacing: Style.space(8)

                            PanelSectionHeader {
                                width: parent.width
                                text: "Event sounds"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Text {
                                textFormat: Text.PlainText
                                text: "Choose the cue for each event from the sound catalog. Choosing a sound previews it."
                                color: Qt.darker(root.foreground, 1.4)
                                font.family: root.fontFamily
                                font.pixelSize: Style.fontPx(0.917)
                                width: parent.width
                                wrapMode: Text.WordWrap
                            }

                            Column {
                                id: soundGrid

                                width: parent.width
                                spacing: Style.space(6)

                                // True while any event-sound dropdown popup is
                                // open; the keyCatcher suspends itself then.
                                // itemAt returns a plain Item to the compiler,
                                // hence the qmllint exemption for the dynamic
                                // popupOpen read.
                                // qmllint disable missing-property
                                readonly property bool popupOpen: {
                                    var open = false;
                                    for (var i = 0; i < soundRepeater.count; i++) {
                                        var item = soundRepeater.itemAt(i);
                                        if (item && item.popupOpen)
                                            open = true;
                                    }
                                    return open;
                                }
                                // qmllint enable missing-property

                                Repeater {
                                    id: soundRepeater

                                    model: root.eventIds

                                    Row {
                                        id: soundRow

                                        required property var modelData
                                        required property int index

                                        // True while this row's dropdown popup
                                        // is open; the grid aggregates these.
                                        readonly property bool popupOpen: soundDropdown.popupOpen

                                        width: parent.width
                                        spacing: Style.space(10)

                                        Text {
                                            textFormat: Text.PlainText
                                            text: root.ctl ? root.ctl.eventLabel(soundRow.modelData) : ""
                                            color: root.foreground
                                            font.family: root.fontFamily
                                            font.pixelSize: Style.fontPx(1.0)
                                            width: 170
                                            elide: Text.ElideRight
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        Dropdown {
                                            id: soundDropdown

                                            width: parent.width - 170 - parent.spacing
                                            showLabel: false
                                            foreground: root.foreground
                                            background: root.background
                                            accent: root.accent
                                            fontFamily: root.fontFamily
                                            options: root.soundOptions()
                                            value: root.eventSoundId(soundRow.modelData)
                                            enabled: root.settingsWritable
                                            opacity: root.settingsWritable ? 1.0 : 0.5
                                            hasCursor: root.cursorActive && root.selectedIndex === root.soundStart + soundRow.index
                                            onHovered: function (h) {
                                                if (h)
                                                    root.select(root.soundStart + soundRow.index);
                                            }
                                            onHasCursorChanged: if (hasCursor)
                                                root.ensureCursorVisible(this)
                                            onChanged: function (v) {
                                                root.setEventSound(soundRow.modelData, v);
                                            }
                                        }
                                    }
                                }
                            }

                            Text {
                                textFormat: Text.PlainText
                                visible: root.previewResult !== ""
                                text: "result: " + root.previewResult
                                color: root.ctl && root.ctl.playing ? root.foreground : Qt.darker(root.foreground, 1.4)
                                font.family: root.fontFamily
                                font.pixelSize: Style.fontPx(0.917)
                                width: parent.width
                                wrapMode: Text.WordWrap
                            }
                        }
                        PanelSeparator {
                            foreground: root.foreground
                        }

                        // ---- diagnostics: ctlStatus (controller.status()
                        // snapshot; the binding re-evaluates on its internal
                        // property reads) plus reactive service fields -------
                        Column {
                            width: parent.width
                            spacing: Style.space(4)

                            PanelSectionHeader {
                                width: parent.width
                                text: "Diagnostics"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Text {
                                textFormat: Text.PlainText
                                text: "settings: " + (root.ctlStatus ? (root.ctlStatus.settingsReady ? "ready from " + (root.ctlStatus.settingsSource === "" ? "defaults" : root.ctlStatus.settingsSource) : "loading…") : "controller unavailable")
                                color: Qt.darker(root.foreground, 1.4)
                                font.family: root.fontFamily
                                font.pixelSize: Style.fontPx(0.833)
                                width: parent.width
                                wrapMode: Text.WordWrap
                            }

                            Text {
                                textFormat: Text.PlainText
                                visible: root.ctlStatus && root.ctlStatus.settingsError !== ""
                                text: "settings error: " + (root.ctlStatus ? root.ctlStatus.settingsError : "")
                                color: root.urgent
                                font.family: root.fontFamily
                                font.pixelSize: Style.fontPx(0.833)
                                width: parent.width
                                wrapMode: Text.WordWrap
                            }

                            Text {
                                textFormat: Text.PlainText
                                text: "safety: " + (root.service ? (root.service.safetyReady ? "ok" : "blocked — " + root.service.safetyReason) : "unavailable")
                                color: Qt.darker(root.foreground, 1.4)
                                font.family: root.fontFamily
                                font.pixelSize: Style.fontPx(0.833)
                                width: parent.width
                                wrapMode: Text.WordWrap
                            }

                            Text {
                                textFormat: Text.PlainText
                                text: "overlap: " + (root.service ? (root.service.overlapBlocked ? "blocked — " + root.service.overlapReason() : "clear") : "unavailable")
                                color: Qt.darker(root.foreground, 1.4)
                                font.family: root.fontFamily
                                font.pixelSize: Style.fontPx(0.833)
                                width: parent.width
                                wrapMode: Text.WordWrap
                            }

                            Text {
                                textFormat: Text.PlainText
                                text: "sources: desktop " + (root.ctlStatus ? (root.ctlStatus.desktopReady ? "ready" : "pending") : "") + ", system " + (root.ctlStatus ? (root.ctlStatus.systemReady ? "ready" : "pending") : "") + ", notifications " + (root.ctlStatus ? (root.ctlStatus.notificationReady ? "ready" : "pending") : "")
                                color: Qt.darker(root.foreground, 1.4)
                                font.family: root.fontFamily
                                font.pixelSize: Style.fontPx(0.833)
                                width: parent.width
                                wrapMode: Text.WordWrap
                            }

                            Text {
                                textFormat: Text.PlainText
                                text: "playback: " + (root.ctlStatus ? (root.ctlStatus.playing ? "playing" + (root.ctlStatus.currentEvent ? " (" + root.ctl.eventLabel(root.ctlStatus.currentEvent) + ")" : "") : "idle") + (root.ctlStatus.cooldownActive ? " · cooldown" : "") : "unavailable")
                                color: Qt.darker(root.foreground, 1.4)
                                font.family: root.fontFamily
                                font.pixelSize: Style.fontPx(0.833)
                                width: parent.width
                                wrapMode: Text.WordWrap
                            }

                            Text {
                                textFormat: Text.PlainText
                                visible: root.ctlStatus && root.ctlStatus.playbackError !== ""
                                text: "playback error: " + (root.ctlStatus ? root.ctlStatus.playbackError : "")
                                color: root.urgent
                                font.family: root.fontFamily
                                font.pixelSize: Style.fontPx(0.833)
                                width: parent.width
                                wrapMode: Text.WordWrap
                            }
                        }

                        Item {
                            width: 1
                            height: Style.space(12)
                        }
                    }
                }
            }
        }
    }
}
