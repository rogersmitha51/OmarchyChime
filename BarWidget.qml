// Chime bar icon. Follows the omarchy.menu bar-widget recipe: the icon is a
// plain BarWidget + WidgetButton; left click toggles the existing on-demand
// settings panel through the shell host (`shell toggle`), right click toggles
// master mute through the live service's controller. No second controller,
// store, player, or observer is created; the plugin's service + panel + keep
// loaded kinds mean the shell keeps routing `shell toggle nick.chime` to the
// panel loader (shell.qml isBarWidgetPanelPlugin excludes panel-kind plugins).

// The bar host injects `bar` (Bar root) and Style.bar tokens without static
// qmltypes data, so qmltype members are unknown to qmllint. First-party
// widgets hit the same limitation (see omarchy audio Panel.qml).
// qmllint disable missing-property

pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "nick.chime"

    // The live service singleton. The bar injects `shell` into widgets; the
    // media widget reaches its service the same way (bar?.shell?.firstPartyServiceFor).
    readonly property var chime: root.bar && root.bar.shell ? root.bar.shell.firstPartyServiceFor("nick.chime") : null
    readonly property var ctl: chime && chime.controllerApi ? chime.controllerApi : null

    readonly property bool muted: ctl ? !ctl.enabled : false

    function toggleMute() {
        if (ctl && ctl.settingsReady)
            ctl.setEnabled(!ctl.enabled);
    }

    function togglePanel() {
        if (root.bar)
            root.bar.run("omarchy-shell shell toggle nick.chime '{}'");
    }

    // Nerd Font bell glyphs (verified in JetBrainsMono Nerd Font):
    // 󰂞 U+F009E bell-ring when sounds are on, 󰂛 U+F009B bell-off when muted.
    // (Literal UTF-8 glyphs: "\u" escapes cover 4 hex digits; 5-digit codepoints
    // would split into \uF009 + "E".)
    // Dimmed while settings are undecided so the icon never looks actionable
    // when the controller cannot act yet.
    readonly property string activeGlyph: "󰂞"
    readonly property string mutedGlyph: "󰂛"

    visible: true
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: root.muted ? root.mutedGlyph : root.activeGlyph
        fontFamily: "JetBrainsMono Nerd Font"
        fontSize: Style.bar.iconFont
        dimmed: root.muted || !root.ctl || !root.ctl.settingsReady
        tooltipText: root.ctl ? (root.muted ? "Chime sounds muted — right click to unmute, left click for settings" : "Chime sounds on — right click to mute, left click for settings") : "Chime unavailable"
        onPressed: function (button) {
            if (button === Qt.RightButton)
                root.toggleMute();
            else
                root.togglePanel();
        }
        onWheelMoved: function (delta) {
            if (!root.ctl || !root.ctl.settingsReady)
                return;
            var step = delta > 0 ? 0.05 : -0.05;
            root.ctl.setVolume(Math.max(0, Math.min(1, root.ctl.volume + step)));
        }
    }
}

// qmllint enable missing-property
