import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "OpenProjectModel.js" as Model

BarWidget {
    id: root
    moduleName: "helderrscorreia.openproject-tasks"

    readonly property string baseUrl: Model.normalizeBaseUrl(setting("openprojectUrl", ""))
    readonly property string apiToken: String(setting("apiToken", "") || "")
    readonly property int pollIntervalSec: Math.max(30, Number(setting("pollIntervalSec", 120)) || 120)
    readonly property int maxTasks: Number(setting("maxTasks", 50)) || 50
    readonly property bool configured: baseUrl !== "" && apiToken !== ""

    property var tasks: []
    property var ongoing: []
    property string loadError: ""
    readonly property string cachePath: Quickshell.env("HOME")
        + "/.local/state/omarchy/openproject-tasks/cache.json"

    readonly property bool timing: ongoing.length > 0
    readonly property string timingTitle: timing ? String(ongoing[0].workPackageTitle || ("#" + ongoing[0].workPackageId)) : ""
    readonly property string tooltipText: {
        if (!root.configured) return "OpenProject: set URL + API token (click for setup)"
        if (root.loadError !== "") return "OpenProject: " + root.loadError
        if (root.timing) return "Timing: " + root.timingTitle + "\n" + root.tasks.length + " open tasks"
        return root.tasks.length + " open tasks assigned to you"
    }

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
    readonly property bool popoutSwitchClosing: panelLoader.item
        ? panelLoader.item.popoutSwitchClosing === true : false

    function open() {
        if (panelLoader.item) panelLoader.item.open()
    }
    function close() {
        if (panelLoader.item) panelLoader.item.close()
    }
    function togglePanel() {
        if (panelLoader.item) panelLoader.item.toggle()
    }
    function closeForPopoutSwitch() {
        if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
    }

    function injectPanel() {
        var target = panelLoader.item
        if (!target) return
        if ("bar" in target) target.bar = root.bar
        if ("settings" in target) target.settings = root.settings
        if ("anchorItem" in target) target.anchorItem = button
        if ("hostWidget" in target) target.hostWidget = root
        if ("service" in target) target.service = service
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    onBarChanged: injectPanel()
    onSettingsChanged: { injectPanel(); Qt.callLater(service.refresh) }

    OpenProjectService {
        id: service
        baseUrl: root.baseUrl
        apiToken: root.apiToken
        maxTasks: root.maxTasks
        Component.onCompleted: Qt.callLater(refresh)
        onCacheChanged: cacheFile.reload()
    }

    Timer {
        id: pollTimer
        interval: root.pollIntervalSec * 1000
        repeat: true
        running: root.configured
        onTriggered: service.refresh()
    }

    FileView {
        id: cacheFile
        path: root.cachePath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                var data = JSON.parse(text())
                root.tasks = data.tasks instanceof Array ? data.tasks : []
                root.ongoing = data.ongoing instanceof Array ? data.ongoing : []
                root.loadError = ""
            } catch (e) { root.loadError = "Cache unreadable." }
        }
        onLoadFailed: {
            if (root.configured) service.refresh()
        }
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel()
            Qt.callLater(root.injectPanel)
        }
    }

    IpcHandler {
        target: "helderrscorreia.openproject-tasks"
        function open(): void { if (panelLoader.item) panelLoader.item.open() }
        function close(): void { if (panelLoader.item) panelLoader.item.close() }
        function toggle(): void { root.togglePanel() }
    }

    // The bar count is rendered in orange while the clock emoji + timing dot keep
    // their own colors. WidgetButton only paints a single-color PlainText, so we
    // render a manual Row of Text items as its child. WidgetButton still supplies
    // the hand cursor, tooltip, click, and click-registration (its internal
    // MouseArea fills the item; the plain Text children don't grab the mouse).
    readonly property color countColor: "#ff9f43"

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        // Non-empty text so WidgetButton's hasVisualContent is true (opacity=1,
        // visible). Its own label is hidden; the child Row renders the colored
        // parts. An empty text would force opacity 0 and hide the widget.
        text: "⏱"
        labelVisible: false
        implicitWidth: row.implicitWidth + Style.spaceReal(12)
        implicitHeight: Style.bar.sizeHorizontal
        foreground: !root.configured ? Color.urgent
            : (root.bar ? root.bar.foreground : Color.foreground)
        tooltipText: root.tooltipText
        onPressed: function(b) {
            if (b === Qt.LeftButton) root.togglePanel()
        }

        Row {
            id: row
            anchors.centerIn: parent
            spacing: Style.spaceReal(4)
            Image {
                id: logoImage
                source: Qt.resolvedUrl("openproject-logo.png")
                sourceSize.width: Math.round(Style.bar.iconFont * 1.6)
                sourceSize.height: Math.round(Style.bar.iconFont * 1.6)
                width: sourceSize.width
                height: sourceSize.height
                smooth: true
                visible: root.configured
            }
            Text {
                id: logoFallback
                textFormat: Text.PlainText
                text: "HP"
                font.family: Style.font.family; font.pixelSize: Style.bar.iconFont
                color: !root.configured ? Color.urgent : (root.bar ? root.bar.foreground : Color.foreground)
                visible: !root.configured
            }
            Text {
                id: dotLabel
                visible: root.timing
                textFormat: Text.PlainText
                text: "●"
                font.family: Style.font.family; font.pixelSize: Style.bar.iconFont
                color: Color.accent
            }
            Text {
                id: countLabel
                textFormat: Text.PlainText
                text: root.configured ? String(root.tasks.length) : "!"
                font.family: Style.font.family; font.pixelSize: Style.bar.iconFont; font.bold: true
                color: root.configured ? root.countColor : Color.urgent
            }
        }
    }
}
