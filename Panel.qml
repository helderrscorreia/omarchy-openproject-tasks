import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "OpenProjectModel.js" as Model

Panel {
    id: root
    moduleName: "helderrscorreia.openproject-tasks"
    ipcTarget: "helderrscorreia.openproject-tasks"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null
    property var service: null
    readonly property var barIdentity: hostWidget || root

    property var tasks: []
    property var ongoing: []
    property string loadError: ""
    property bool settingsOpen: false
    property string actionMessage: ""
    property string searchQuery: ""

    // Case-insensitive filter over the fields most useful for finding a task.
    readonly property var visibleTasks: {
        var q = root.searchQuery.trim().toLowerCase()
        if (q === "") return root.tasks
        return root.tasks.filter(function(t) {
            return String(t.subject || "").toLowerCase().indexOf(q) !== -1
                || String(t.id || "").toLowerCase().indexOf(q) !== -1
                || String(t.project || "").toLowerCase().indexOf(q) !== -1
                || String(t.status || "").toLowerCase().indexOf(q) !== -1
                || String(t.type || "").toLowerCase().indexOf(q) !== -1
                || String(t.priority || "").toLowerCase().indexOf(q) !== -1
        })
    }
    readonly property string cachePath: Quickshell.env("HOME")
        + "/.local/state/omarchy/openproject-tasks/cache.json"

    readonly property string baseUrl: Model.normalizeBaseUrl(setting("openprojectUrl", ""))
    readonly property bool hasToken: String(setting("apiToken", "") || "") !== ""
    readonly property bool configured: baseUrl !== "" && hasToken
    readonly property color contentForeground: bar ? bar.foreground : Color.foreground
    readonly property color mutedForeground: Qt.rgba(contentForeground.r, contentForeground.g, contentForeground.b, 0.6)
    readonly property color accentForeground: Color.accent
    readonly property bool busy: service ? service.busy : false
    readonly property string serviceError: service ? String(service.lastError || "") : ""
    readonly property string effectiveError: root.loadError !== "" ? root.loadError : root.serviceError

    property string urlDraft: ""
    property string tokenDraft: ""
    property string saveMessage: ""
    property bool justSaved: false
    // The click that opens the panel has a release event that, during the
    // Exclusive focus prime, lands on the dismissal surface and would close it
    // instantly. Suppress any close that arrives within a short window of open.
    property double openedAt: 0
    readonly property string draftTokenUrl: Model.tokenUrlFor(
        root.urlDraft.trim() !== "" ? root.urlDraft : String(setting("openprojectUrl", "") || ""))

    // Comment draft per task id for the inline label field
    property string commentDraftTaskId: ""
    property string commentDraft: ""

    function resetDrafts() {
        var savedUrl = String(setting("openprojectUrl", "") || "")
        root.urlDraft = savedUrl
        root.tokenDraft = ""
        root.saveMessage = ""
        if (urlField && urlField.text !== savedUrl) urlField.text = savedUrl
        if (tokenField && tokenField.text !== "") tokenField.text = ""
    }
    function saveSetting(key, value) {
        if (saveProcess.running) return
        root.saveMessage = "Saving..."
        root.justSaved = true
        saveProcess.command = ["/usr/bin/omarchy", "bar", "set",
            root.moduleName, key, String(value)]
        saveProcess.running = true
    }

    onSettingsOpenChanged: if (settingsOpen) resetDrafts()
    onConfiguredChanged: {
        if (configured && justSaved) {
            justSaved = false
            settingsOpen = false
        }
    }
    Component.onCompleted: resetDrafts()

    function open() {
        root.openedAt = Date.now()
        if (!root.configured) root.settingsOpen = true
        if (service) service.refresh()
        cacheFile.reload()
        root.controller.show()
    }
    function close() {
        // The opening click's mouse-up is often re-routed to the dismissal
        // surface during the Exclusive focus prime and calls close() right
        // after open(). A genuine outside-click that quickly is impossible, so
        // drop it to keep the panel open after a widget click.
        if (Date.now() - root.openedAt < 300) return
        root.settingsOpen = false
        root.controller.hide()
    }
    function toggle() {
        if (root.opened) root.close(); else root.open()
    }
    function switchPanel(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root.barIdentity, direction)
        return false
    }
    function openWorkPackage(id) {
        var wp = String(id || "")
        if (!wp || !root.baseUrl) return
        Qt.openUrlExternally(root.baseUrl + "/work_packages/" + wp.replace(/[^0-9]/g, ""))
    }
    function newTask() {
        if (!root.baseUrl) return
        // Open the web UI's create-work-package flow (lets the user pick
        // project + type). Optionally pre-target the first open task's project
        // so the new task lands in the same project context.
        var projectId = ""
        if (root.tasks.length > 0 && root.tasks[0].projectId) {
            projectId = "?project_id=" + String(root.tasks[0].projectId).replace(/[^0-9]/g, "")
        }
        Qt.openUrlExternally(root.baseUrl + "/work_packages/new" + projectId)
    }
    function openTaskInBrowser(task) {
        if (!task) return
        if (task.href) {
            var m = String(task.href).match(/\/work_packages\/(\d+)/)
            if (m) return root.openWorkPackage(m[1])
        }
        root.openWorkPackage(task.id)
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
                root.tasks = Model.sortedTasks(data.tasks instanceof Array ? data.tasks : [])
                root.ongoing = data.ongoing instanceof Array ? data.ongoing : []
                root.loadError = data.error ? String(data.error) : ""
            } catch (e) { root.loadError = "Cache unreadable. Refresh to retry." }
        }
        onLoadFailed: {
            root.tasks = []; root.ongoing = []
            root.loadError = root.configured ? "No data yet. Press Refresh." : ""
        }
    }

    Timer { id: tick; interval: 1000; repeat: true; running: root.opened && root.ongoing.length > 0; onTriggered: elapsedText.refresh() }
    QtObject {
        id: elapsedText
        property int n: 0
        function refresh() { n++ }
        readonly property string label: root.ongoing.length > 0
            ? Model.elapsedLabel(root.ongoing[0].createdAt, Date.now() + 0 * n) : ""
    }

    Process {
        id: saveProcess
        running: false
        stdout: StdioCollector { id: saveOut; waitForEnd: true }
        stderr: StdioCollector { id: saveErr; waitForEnd: true }
        onExited: function(code) {
            if (code === 0) {
                root.saveMessage = "Saved."
                root.tokenDraft = ""
                if (service) Qt.callLater(service.refresh)
            } else {
                root.justSaved = false
                var msg = String(saveErr.text || saveOut.text || "Save failed.").replace(/\s+/g, " ").trim()
                root.saveMessage = msg.length > 220 ? msg.substring(0, 217) + "..." : msg
            }
        }
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: Style.space(440)
        contentHeight: Style.space(580)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function(d) { root.switchPanel(d) }

            Column {
                anchors.fill: parent
                anchors.margins: Style.space(16)
                spacing: Style.space(10)

                // Header
                Item {
                    width: parent.width; height: Style.space(32)
                    Row {
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)
                        Image {
                            source: Qt.resolvedUrl("openproject-logo.png")
                            sourceSize.width: Style.space(18)
                            sourceSize.height: Style.space(18)
                            width: sourceSize.width
                            height: sourceSize.height
                            smooth: true
                        }
                        Text {
                            textFormat: Text.PlainText
                            text: "OPENPROJECT TASKS"
                            color: root.contentForeground
                            font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; font.bold: true
                        }
                    }
                    Button {
                        anchors.right: newTaskButton.left; anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Refresh"; bordered: true
                        enabled: root.configured && !root.busy
                        horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                        onClicked: { root.actionMessage = ""; service.refresh(); cacheFile.reload() }
                    }
                    Button {
                        id: newTaskButton
                        anchors.right: settingsButton.left; anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "+ New task"; bordered: true
                        enabled: root.configured
                        tooltipText: "Create a new work package in OpenProject"
                        horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                        onClicked: root.newTask()
                    }
                    Button {
                        id: settingsButton
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        iconText: "󰒓"; tooltipText: "Setup (URL + token)"
                        bordered: true; selected: root.settingsOpen
                        horizontalPadding: Style.space(7); verticalPadding: Style.space(4)
                        onClicked: root.settingsOpen = !root.settingsOpen
                    }
                }

                // Setup view
                Column {
                    visible: root.settingsOpen
                    width: parent.width; spacing: Style.space(8)
                    Text {
                        textFormat: Text.PlainText; width: parent.width; wrapMode: Text.Wrap
                        text: "SETUP"
                        color: root.accentForeground
                        font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true
                    }
                    Text {
                        textFormat: Text.PlainText; width: parent.width; wrapMode: Text.Wrap
                        text: "1. OpenProject instance URL"
                        color: root.mutedForeground
                        font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
                    }
                    TextField {
                        id: urlField
                        width: parent.width
                        placeholderText: "https://projects.example.com"
                        onTextChanged: root.urlDraft = text
                        onAccepted: {
                            if (root.urlDraft.trim() !== "" && !saveProcess.running)
                                root.saveSetting("openprojectUrl", root.urlDraft.trim())
                        }
                    }
                    Row {
                        spacing: Style.space(6)
                        Button {
                            text: "Save URL"; bordered: true
                            enabled: root.urlDraft.trim() !== "" && !saveProcess.running
                            horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                            onClicked: root.saveSetting("openprojectUrl", root.urlDraft.trim())
                        }
                        Button {
                            text: "Generate API token ↗"; bordered: true
                            enabled: root.draftTokenUrl !== ""
                            tooltipText: root.draftTokenUrl
                            horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                            onClicked: Qt.openUrlExternally(root.draftTokenUrl)
                        }
                    }
                    Text {
                        visible: root.draftTokenUrl !== ""
                        textFormat: Text.PlainText; width: parent.width; wrapMode: Text.Wrap
                        text: root.draftTokenUrl + "  →  + API Token, then paste it below."
                        color: root.mutedForeground
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                    }
                    Text {
                        textFormat: Text.PlainText; width: parent.width; wrapMode: Text.Wrap
                        text: "2. API token" + (root.hasToken ? " (already saved — new one replaces it)" : "")
                        color: root.mutedForeground
                        font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
                    }
                    TextField {
                        id: tokenField
                        width: parent.width
                        password: true
                        placeholderText: "Paste token here"
                        onTextChanged: root.tokenDraft = text
                        onAccepted: {
                            if (root.tokenDraft !== "" && !saveProcess.running)
                                root.saveSetting("apiToken", root.tokenDraft)
                        }
                    }
                    Button {
                        text: "Save token"; bordered: true
                        enabled: root.tokenDraft !== "" && !saveProcess.running
                        horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                        onClicked: root.saveSetting("apiToken", root.tokenDraft)
                    }
                    Text {
                        visible: root.saveMessage !== ""
                        textFormat: Text.PlainText; width: parent.width; wrapMode: Text.Wrap
                        text: root.saveMessage
                        color: root.mutedForeground
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                    }
                }

                // Status / error line
                Text {
                    visible: !root.settingsOpen && (root.effectiveError !== "" || (service && service.lastStatus !== "") || root.actionMessage !== "")
                    textFormat: Text.PlainText; width: parent.width; wrapMode: Text.Wrap
                    text: root.effectiveError !== "" ? root.effectiveError
                        : (service && service.lastStatus !== "" ? service.lastStatus : root.actionMessage)
                    color: root.effectiveError !== "" ? root.accentForeground : root.mutedForeground
                    font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
                }

                // Ongoing timer card
                Rectangle {
                    visible: !root.settingsOpen && root.configured && root.ongoing.length > 0
                    width: parent.width; height: ongoingCol.implicitHeight + Style.space(14)
                    radius: Style.cornerRadius
                    color: Qt.rgba(root.accentForeground.r, root.accentForeground.g, root.accentForeground.b, 0.14)
                    Column {
                        id: ongoingCol
                        anchors.left: parent.left; anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Style.space(8); spacing: Style.space(4)
                        Text {
                            textFormat: Text.PlainText; width: parent.width; wrapMode: Text.Wrap
                            text: "● TIMING  " + (root.ongoing.length > 0 ? ("#" + root.ongoing[0].workPackageId + "  " + root.ongoing[0].workPackageTitle) : "")
                            color: root.contentForeground
                            font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true
                        }
                        Text {
                            visible: root.ongoing.length > 0 && root.ongoing[0].comment !== ""
                            textFormat: Text.PlainText; width: parent.width; wrapMode: Text.Wrap
                            text: root.ongoing.length > 0 ? root.ongoing[0].comment : ""
                            color: root.mutedForeground
                            font.family: Style.font.family; font.pixelSize: Style.font.caption
                            font.italic: true
                        }
                        Row {
                            spacing: Style.space(6)
                            Text {
                                textFormat: Text.PlainText
                                text: elapsedText.label
                                color: root.mutedForeground
                                font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
                            }
                            Button {
                                text: "Open"; bordered: true
                                horizontalPadding: Style.space(8); verticalPadding: Style.space(3)
                                onClicked: root.openWorkPackage(root.ongoing[0].workPackageId)
                            }
                            Button {
                                text: root.busy ? "Working…" : "Stop"; bordered: true; enabled: !root.busy
                                horizontalPadding: Style.space(8); verticalPadding: Style.space(3)
                                onClicked: { root.actionMessage = ""; service.stopTimer(root.ongoing[0].id) }
                            }
                        }
                    }
                }

                // Task search
                Row {
                    visible: !root.settingsOpen && root.configured
                    width: parent.width; spacing: Style.space(6)
                    TextField {
                        id: searchField
                        width: parent.width - clearBtn.implicitWidth - Style.space(6)
                        placeholderText: "Search tasks…"
                        text: root.searchQuery
                        onTextChanged: root.searchQuery = text
                    }
                    Button {
                        id: clearBtn
                        text: "✕"; bordered: true
                        enabled: root.searchQuery !== ""
                        horizontalPadding: Style.space(8); verticalPadding: Style.space(5)
                        onClicked: { root.searchQuery = ""; searchField.text = "" }
                    }
                }

                // Task list
                Flickable {
                    visible: !root.settingsOpen
                    width: parent.width; height: Math.max(0, parent.height - y)
                    contentWidth: width; contentHeight: taskCol.implicitHeight
                    clip: true; boundsBehavior: Flickable.StopAtBounds
                    Column {
                        id: taskCol
                        width: parent.width; spacing: Style.space(6)
                        Repeater {
                            model: root.configured ? root.visibleTasks : []
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool isTiming: root.ongoing.length > 0
                                    && String(root.ongoing[0].workPackageId) === String(modelData.id)
                                readonly property bool showCommentField: root.commentDraftTaskId === String(modelData.id)
                                width: taskCol.width
                                height: taskInner.implicitHeight + Style.space(10)
                                radius: Style.cornerRadius
                                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, isTiming ? 0.14 : 0.07)
                                Column {
                                    id: taskInner
                                    anchors.left: parent.left; anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.margins: Style.space(7); spacing: Style.space(3)
                                    Row {
                                        spacing: Style.space(6); width: parent.width
                                        Rectangle {
                                            width: prioText.implicitWidth + Style.space(12); height: Style.space(20)
                                            radius: Style.space(10)
                                            color: Model.priorityColor(modelData.priority, root.accentForeground)
                                            Text {
                                                id: prioText; anchors.centerIn: parent
                                                textFormat: Text.PlainText
                                                text: String(modelData.priority || "—").toUpperCase()
                                                color: "#1a1a1a"
                                                font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true
                                            }
                                        }
                                        Text {
                                            textFormat: Text.PlainText
                                            width: parent.width - x; elide: Text.ElideRight
                                            text: "#" + modelData.id + "  " + modelData.subject
                                            color: root.contentForeground
                                            font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: isTiming
                                        }
                                    }
                                    Row {
                                        width: parent.width; spacing: Style.space(6)
                                        Text {
                                            textFormat: Text.PlainText
                                            text: (modelData.status || "")
                                            color: Model.statusColor(modelData.status) || root.mutedForeground
                                            font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true
                                        }
                                        Text {
                                            textFormat: Text.PlainText
                                            text: (modelData.type ? (modelData.project ? modelData.project + "  ·  " : "") + modelData.type : (modelData.project ? modelData.project : ""))
                                            color: root.mutedForeground
                                            font.family: Style.font.family; font.pixelSize: Style.font.caption
                                            elide: Text.ElideRight; width: parent.width - x
                                        }
                                    }
                                    // Comment field (shown when starting a timer)
                                    Row {
                                        visible: showCommentField
                                        width: parent.width; spacing: Style.space(4)
                                        TextField {
                                            id: commentField
                                            width: parent.width - commentStartBtn.width - Style.space(4)
                                            placeholderText: "Label / comment for this timer..."
                                            text: root.commentDraft
                                            onTextChanged: root.commentDraft = text
                                            onAccepted: {
                                                root.actionMessage = ""
                                                service.startTimer(modelData.id, root.commentDraft)
                                                root.commentDraftTaskId = ""
                                                root.commentDraft = ""
                                            }
                                        }
                                        Button {
                                            id: commentStartBtn
                                            text: "Go"; bordered: true; enabled: !root.busy
                                            horizontalPadding: Style.space(7); verticalPadding: Style.space(3)
                                            onClicked: {
                                                root.actionMessage = ""
                                                service.startTimer(modelData.id, root.commentDraft)
                                                root.commentDraftTaskId = ""
                                                root.commentDraft = ""
                                            }
                                        }
                                    }
                                    Row {
                                        spacing: Style.space(6)
                                        Button {
                                            text: isTiming ? "Timing ●" : (root.ongoing.length > 0 ? "Switch" : "Start")
                                            bordered: true; enabled: !root.busy
                                            horizontalPadding: Style.space(7); verticalPadding: Style.space(3)
                                            onClicked: {
                                                root.actionMessage = ""
                                                if (isTiming) {
                                                    service.stopTimer(root.ongoing[0].id)
                                                } else if (root.ongoing.length > 0) {
                                                    // Switching: show comment field for label
                                                    root.commentDraftTaskId = String(modelData.id)
                                                    root.commentDraft = ""
                                                } else {
                                                    // First timer: show comment field for label
                                                    root.commentDraftTaskId = String(modelData.id)
                                                    root.commentDraft = ""
                                                }
                                            }
                                        }
                                        Button {
                                            text: "Open"; bordered: true
                                            horizontalPadding: Style.space(7); verticalPadding: Style.space(3)
                                            onClicked: root.openTaskInBrowser(modelData)
                                        }
                                    }
                                }
                            }
                        }
                        Text {
                            visible: !root.configured && root.effectiveError === ""
                            textFormat: Text.PlainText; width: parent.width
                            text: "Not connected yet — open Setup (gear icon) to enter your OpenProject URL and API token."
                            color: root.mutedForeground
                            font.family: Style.font.family; font.pixelSize: Style.font.body
                            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                            topPadding: Style.space(18)
                        }
                        Text {
                            visible: root.configured && root.tasks.length === 0 && root.effectiveError === ""
                            textFormat: Text.PlainText; width: parent.width
                            text: "No open tasks assigned to you."
                            color: root.mutedForeground
                            font.family: Style.font.family; font.pixelSize: Style.font.body
                            horizontalAlignment: Text.AlignHCenter; topPadding: Style.space(18)
                        }
                        Text {
                            visible: root.configured && root.tasks.length > 0 && root.visibleTasks.length === 0
                            textFormat: Text.PlainText; width: parent.width
                            text: "No tasks match \"" + root.searchQuery + "\"."
                            color: root.mutedForeground
                            font.family: Style.font.family; font.pixelSize: Style.font.body
                            horizontalAlignment: Text.AlignHCenter; topPadding: Style.space(18)
                        }
                    }
                }
            }
        }
    }
}
