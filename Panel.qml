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
    property var statuses: []
    property var priorities: []
    property string loadError: ""
    property bool settingsOpen: false
    property string actionMessage: ""
    property string searchQuery: ""
    property string editingTaskId: ""
    // Label draft for the running timer; tied to the time entry id so polling
    // does not overwrite what the user is typing.
    property string labelDraft: ""
    property string labelEntryId: ""
    property bool pendingVerify: false
    property int verifyAttempts: 0

    // Reference lists from the cache -> { value, label } for the pickers.
    property var statusOptions: []
    property var priorityOptions: []

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
    readonly property bool hasToken: service ? service.hasToken : false
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
    // The click that opens the panel has a release event that, during the
    // Exclusive focus prime, lands on the dismissal surface and would close it
    // instantly. Suppress any close that arrives within a short window of open.
    property double openedAt: 0
    readonly property string draftTokenUrl: Model.tokenUrlFor(
        root.urlDraft.trim() !== "" ? root.urlDraft : String(setting("openprojectUrl", "") || ""))

    // Keep the label field in sync with the running entry without clobbering
    // edits while the user types (polling replaces the ongoing array).
    function syncLabelDraft() {
        var entry = root.ongoing.length > 0 ? root.ongoing[0] : null
        var id = entry ? String(entry.id || "") : ""
        if (id === root.labelEntryId) return
        root.labelEntryId = id
        root.labelDraft = entry ? String(entry.comment || "") : ""
    }
    function saveLabel() {
        var entry = root.ongoing.length > 0 ? root.ongoing[0] : null
        if (!entry || !service || root.busy) return
        root.actionMessage = ""
        service.updateComment(entry.id, root.labelDraft)
    }
    function startTask(task) {
        if (!task || !service || root.busy) return
        root.actionMessage = ""
        service.startTimer(task.id)
    }
    function focusSearch() {
        Qt.callLater(function() {
            if (root.configured && !root.settingsOpen && searchField)
                searchField.forceActiveFocus()
        })
    }
    // After saving the URL/token, check the connection instead of closing
    // Setup blindly; close only once a refresh succeeded.
    function verifyConnection() {
        if (!service) return
        // The URL/token watchers can lag the helper process by a tick; retry
        // briefly before declaring setup incomplete.
        if (!root.configured && root.verifyAttempts < 10) {
            root.verifyAttempts++
            verifyDelay.restart()
            return
        }
        if (!root.configured) {
            root.verifyAttempts = 0
            root.saveMessage = "Saved. Add an API token to connect."
            return
        }
        if (service.busy) {
            // Let an in-flight poll finish; its result cannot verify the new
            // settings, so try again once the service is idle.
            verifyDelay.restart()
            return
        }
        root.verifyAttempts = 0
        root.pendingVerify = true
        root.saveMessage = "Checking connection…"
        verifyTimer.restart()
        service.refresh()
    }

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
        saveProcess.command = ["/usr/bin/omarchy", "bar", "set",
            root.moduleName, key, String(value)]
        saveProcess.running = true
    }
    // Save the API token into the private (0600) file via the helper. The
    // secret travels over stdin (never argv) and is cleared from memory
    // immediately once handed to the process.
    function saveToken() {
        if (tokenProcess.running) return
        var token = root.tokenDraft
        if (!token) return
        root.saveMessage = "Saving..."
        tokenProcess.secret = token
        // Purge the secret from editable state as soon as it is captured so a
        // defensively-minded scan sees it leave the QML context.
        root.tokenDraft = ""
        if (tokenField) tokenField.text = ""
        tokenProcess.command = ["/usr/bin/python3", root.helperPath,
            "--token-file", root.tokenFilePath, "--token-stdin", "save-token"]
        tokenProcess.running = true
    }
    readonly property string helperPath: service ? service.helperPath : ""
    readonly property string tokenFilePath: service ? service.tokenFilePath : ""

    onSettingsOpenChanged: if (settingsOpen) resetDrafts()
    onOngoingChanged: root.syncLabelDraft()
    Component.onCompleted: resetDrafts()

    function open() {
        root.openedAt = Date.now()
        if (!root.configured) root.settingsOpen = true
        if (service) service.refresh()
        cacheFile.reload()
        root.syncLabelDraft()
        root.controller.show()
        root.focusSearch()
    }
    function close() {
        // The opening click's mouse-up is often re-routed to the dismissal
        // surface during the Exclusive focus prime and calls close() right
        // after open(). A genuine outside-click that quickly is impossible, so
        // drop it to keep the panel open after a widget click.
        if (Date.now() - root.openedAt < 300) return
        root.settingsOpen = false
        root.editingTaskId = ""
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
    function openMyPage() {
        if (!root.baseUrl) return
        Qt.openUrlExternally(root.baseUrl + "/my/page")
    }
    function openTaskInBrowser(task) {
        if (!task) return
        if (task.href) {
            var m = String(task.href).match(/\/work_packages\/(\d+)/)
            if (m) return root.openWorkPackage(m[1])
        }
        root.openWorkPackage(task.id)
    }
    function applyTaskEdit(task, statusId, priorityId) {
        if (!task || !service) return
        root.actionMessage = ""
        root.editingTaskId = ""
        service.updateTask(task.id, statusId, priorityId)
    }
    function editingTask() {
        if (root.editingTaskId === "") return null
        for (var i = 0; i < root.tasks.length; i++) {
            if (String(root.tasks[i].id) === root.editingTaskId) return root.tasks[i]
        }
        return null
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
                root.statuses = data.statuses instanceof Array ? data.statuses : []
                root.priorities = data.priorities instanceof Array ? data.priorities : []
                root.statusOptions = root.statuses.slice().sort(function(a, b) {
                    var na = String(a.name || "").toLowerCase(), nb = String(b.name || "").toLowerCase()
                    return na < nb ? -1 : (na > nb ? 1 : 0)
                }).map(function(s) { return { value: String(s.id), label: String(s.name || "?") } })
                root.priorityOptions = root.priorities.map(function(p) {
                    return { value: String(p.id), label: String(p.name || "?") }
                })
                root.loadError = data.error ? String(data.error) : ""
            } catch (e) { root.loadError = "Cache unreadable. Refresh to retry." }
        }
        onLoadFailed: {
            root.tasks = []; root.ongoing = []
            root.loadError = root.configured ? "No data yet. Press Refresh." : ""
        }
    }

    Timer { id: tick; interval: 1000; repeat: true; running: root.opened && root.ongoing.length > 0; onTriggered: elapsedText.refresh() }
    Timer {
        id: verifyTimer
        interval: 12000
        repeat: false
        onTriggered: {
            if (!root.pendingVerify) return
            root.pendingVerify = false
            root.saveMessage = "No response from OpenProject. Check the URL and try again."
        }
    }
    Timer {
        id: verifyDelay
        interval: 200
        repeat: false
        onTriggered: root.verifyConnection()
    }
    Timer {
        id: closeTimer
        interval: 900
        repeat: false
        onTriggered: root.settingsOpen = false
    }

    Connections {
        target: root.service
        function onStatusDone(ok, message) {
            if (!root.pendingVerify) return
            root.pendingVerify = false
            verifyTimer.stop()
            if (ok) {
                root.saveMessage = "Connected ✓"
                closeTimer.restart()
            } else {
                root.saveMessage = "Connection failed: " + (message !== "" ? message : "unknown error")
            }
        }
    }
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
                Qt.callLater(root.verifyConnection)
            } else {
                var msg = String(saveErr.text || saveOut.text || "Save failed.").replace(/\s+/g, " ").trim()
                root.saveMessage = msg.length > 220 ? msg.substring(0, 217) + "..." : msg
            }
        }
    }

    Process {
        id: tokenProcess
        property string secret: ""
        running: false
        stdinEnabled: true
        stdout: StdioCollector { id: tokenOut; waitForEnd: true }
        stderr: StdioCollector { id: tokenErr; waitForEnd: true }
        onStarted: {
            // Hand the secret off and purge it from QML memory immediately.
            write(tokenProcess.secret + "\n")
            tokenProcess.secret = ""
        }
        onExited: function(code) {
            if (code === 0) {
                Qt.callLater(root.verifyConnection)
            } else {
                var msg = String(tokenErr.text || tokenOut.text || "Token save failed.").replace(/\s+/g, " ").trim()
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
                        id: myPageButton
                        anchors.right: newTaskButton.left; anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "My page"; bordered: true
                        enabled: root.configured
                        tooltipText: "Open your OpenProject My page"
                        horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                        onClicked: { root.openMyPage(); root.close() }
                    }
                    Button {
                        id: newTaskButton
                        anchors.right: refreshButton.left; anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "+ New task"; bordered: true
                        enabled: root.configured
                        tooltipText: "Create a new work package in OpenProject"
                        horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                        onClicked: root.newTask()
                    }
                    Button {
                        id: refreshButton
                        anchors.right: settingsButton.left; anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        iconText: "󰑐"; tooltipText: "Refresh tasks"
                        bordered: true
                        enabled: root.configured && !root.busy
                        horizontalPadding: Style.space(7); verticalPadding: Style.space(4)
                        onClicked: { root.actionMessage = ""; service.refresh(); cacheFile.reload() }
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

                // Setup view (scrollable so long URLs/messages cannot clip it)
                Flickable {
                    id: setupScroll
                    visible: root.settingsOpen
                    width: parent.width; height: Math.max(0, parent.height - y)
                    contentWidth: width; contentHeight: setupCol.implicitHeight
                    clip: true; boundsBehavior: Flickable.StopAtBounds
                    Column {
                    id: setupCol
                    width: setupScroll.width; spacing: Style.space(8)
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
                            if (root.tokenDraft !== "" && !tokenProcess.running)
                                root.saveToken()
                        }
                    }
                    Button {
                        text: "Save token"; bordered: true
                        enabled: root.tokenDraft !== "" && !tokenProcess.running
                        horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                        onClicked: root.saveToken()
                    }
                    Text {
                        visible: root.saveMessage !== ""
                        textFormat: Text.PlainText; width: parent.width; wrapMode: Text.Wrap
                        text: root.saveMessage
                        color: root.mutedForeground
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                    }

                    Row {
                        width: parent.width; spacing: Style.space(8)
                        Text {
                            textFormat: Text.PlainText; width: parent.width - aboutLink.width - Style.space(8)
                            wrapMode: Text.Wrap; anchors.verticalCenter: parent.verticalCenter
                            text: "Free, open-source project management."
                            color: root.mutedForeground
                            font.family: Style.font.family; font.pixelSize: Style.font.caption
                        }
                        Button {
                            id: aboutLink
                            text: "openproject.org ↗"; bordered: true
                            horizontalPadding: Style.space(8); verticalPadding: Style.space(3)
                            onClicked: Qt.openUrlExternally("https://www.openproject.org")
                        }
                    }
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
                        Row {
                            width: parent.width; spacing: Style.space(4)
                            TextField {
                                id: labelField
                                width: parent.width - saveLabelBtn.width - Style.space(4)
                                placeholderText: "Add a label / comment…"
                                text: root.labelDraft
                                onTextChanged: root.labelDraft = text
                                onAccepted: root.saveLabel()
                            }
                            Button {
                                id: saveLabelBtn
                                text: "Save label"; bordered: true; enabled: !root.busy
                                horizontalPadding: Style.space(7); verticalPadding: Style.space(3)
                                onClicked: root.saveLabel()
                            }
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
                                onClicked: { root.openWorkPackage(root.ongoing[0].workPackageId); root.close() }
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
                        onAccepted: {
                            if (root.visibleTasks.length === 0) return
                            var task = root.visibleTasks[0]
                            var timing = root.ongoing.length > 0
                                && String(root.ongoing[0].workPackageId) === String(task.id)
                            if (timing) {
                                root.actionMessage = ""
                                service.stopTimer(root.ongoing[0].id)
                            } else {
                                root.startTask(task)
                            }
                        }
                    }
                    Button {
                        id: clearBtn
                        text: "✕"; bordered: true
                        enabled: root.searchQuery !== ""
                        horizontalPadding: Style.space(8); verticalPadding: Style.space(5)
                        onClicked: { root.searchQuery = ""; searchField.text = ""; searchField.forceActiveFocus() }
                    }
                }
                Text {
                    visible: !root.settingsOpen && root.configured
                    textFormat: Text.PlainText; width: parent.width; wrapMode: Text.Wrap
                    text: "Esc closes · Enter starts or stops the top result"
                    color: root.mutedForeground
                    font.family: Style.font.family; font.pixelSize: Style.font.caption
                }

                // Edit task view (status/priority pickers)
                Column {
                    visible: !root.settingsOpen && root.configured && root.editingTaskId !== ""
                    width: parent.width; spacing: Style.space(8)
                    Row {
                        width: parent.width
                        Text {
                            textFormat: Text.PlainText; elide: Text.ElideRight; width: parent.width - cancelEditBtn.implicitWidth - Style.space(6)
                            text: {
                                var t = root.editingTask()
                                return t ? ("Edit  #" + t.id + "  " + t.subject) : "Edit task"
                            }
                            color: root.accentForeground
                            font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true
                        }
                        Button {
                            id: cancelEditBtn
                            text: "✕"; bordered: true; enabled: !root.busy
                            horizontalPadding: Style.space(7); verticalPadding: Style.space(3)
                            onClicked: { root.actionMessage = ""; root.editingTaskId = "" }
                        }
                    }
                    Dropdown {
                        id: editStatusDrop
                        width: parent.width
                        label: "Status"
                        options: root.statusOptions
                        value: root.editingTask() ? String(root.editingTask().statusId || "") : ""
                        fontFamily: Style.font.family
                    }
                    Dropdown {
                        id: editPriorityDrop
                        width: parent.width
                        label: "Priority"
                        options: root.priorityOptions
                        value: root.editingTask() ? String(root.editingTask().priorityId || "") : ""
                        fontFamily: Style.font.family
                    }
                    Row {
                        spacing: Style.space(6)
                        Button {
                            text: "Apply"; bordered: true; enabled: !root.busy
                            horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                            onClicked: root.applyTaskEdit(root.editingTask(), editStatusDrop.value, editPriorityDrop.value)
                        }
                        Button {
                            text: "Cancel"; bordered: true
                            horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                            onClicked: { root.actionMessage = ""; root.editingTaskId = "" }
                        }
                    }
                    Text {
                        visible: root.statusOptions.length === 0 || root.priorityOptions.length === 0
                        textFormat: Text.PlainText; width: parent.width; wrapMode: Text.Wrap
                        text: "Status/priority lists unavailable — press Refresh and try again."
                        color: root.mutedForeground
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                    }
                }

                // Task list
                Flickable {
                    visible: !root.settingsOpen && root.editingTaskId === ""
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
                                            id: titleText
                                            textFormat: Text.PlainText
                                            width: parent.width - x; elide: Text.ElideRight
                                            text: "#" + modelData.id + "  " + modelData.subject
                                            color: titleMouse.containsMouse || isTiming ? root.accentForeground : root.contentForeground
                                            font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: isTiming
                                            MouseArea {
                                                id: titleMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.openTaskInBrowser(modelData); root.close() }
                                            }
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
                                    Row {
                                        spacing: Style.space(6)
                                        Button {
                                            text: isTiming ? "Timing ●" : (root.ongoing.length > 0 ? "Switch" : "Start")
                                            bordered: true; enabled: !root.busy
                                            tooltipText: isTiming ? "Stop this timer" : "Start tracking this task"
                                            horizontalPadding: Style.space(7); verticalPadding: Style.space(3)
                                            onClicked: {
                                                if (isTiming) {
                                                    root.actionMessage = ""
                                                    service.stopTimer(root.ongoing[0].id)
                                                } else {
                                                    root.startTask(modelData)
                                                }
                                            }
                                        }
                                        Button {
                                            text: "Edit"; bordered: true; enabled: !root.busy
                                            selected: root.editingTaskId === String(modelData.id)
                                            tooltipText: "Change status / priority"
                                            horizontalPadding: Style.space(7); verticalPadding: Style.space(3)
                                            onClicked: {
                                                root.actionMessage = ""
                                                root.editingTaskId = root.editingTaskId === String(modelData.id) ? "" : String(modelData.id)
                                            }
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
                        Row {
                            visible: !root.configured && root.effectiveError === ""
                            anchors.horizontalCenter: parent.horizontalCenter
                            Button {
                                text: "Open setup"; bordered: true
                                horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                                onClicked: root.settingsOpen = true
                            }
                        }
                        Text {
                            visible: root.configured && root.tasks.length === 0 && root.effectiveError === ""
                            textFormat: Text.PlainText; width: parent.width
                            text: "No open tasks assigned to you."
                            color: root.mutedForeground
                            font.family: Style.font.family; font.pixelSize: Style.font.body
                            horizontalAlignment: Text.AlignHCenter; topPadding: Style.space(18)
                        }
                        Row {
                            visible: root.configured && root.tasks.length === 0 && root.effectiveError === ""
                            anchors.horizontalCenter: parent.horizontalCenter
                            Button {
                                text: "+ New task"; bordered: true
                                horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                                onClicked: root.newTask()
                            }
                        }
                        Text {
                            visible: root.configured && root.tasks.length > 0 && root.visibleTasks.length === 0
                            textFormat: Text.PlainText; width: parent.width
                            text: "No tasks match \"" + root.searchQuery + "\"."
                            color: root.mutedForeground
                            font.family: Style.font.family; font.pixelSize: Style.font.body
                            horizontalAlignment: Text.AlignHCenter; topPadding: Style.space(18)
                        }
                        Row {
                            visible: root.configured && root.tasks.length > 0 && root.visibleTasks.length === 0
                            anchors.horizontalCenter: parent.horizontalCenter
                            Button {
                                text: "Clear search"; bordered: true
                                horizontalPadding: Style.space(8); verticalPadding: Style.space(4)
                                onClicked: { root.searchQuery = ""; searchField.text = ""; searchField.forceActiveFocus() }
                            }
                        }
                    }
                }
            }
        }
    }
}
