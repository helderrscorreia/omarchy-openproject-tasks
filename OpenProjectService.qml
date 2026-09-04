import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    property string baseUrl: ""
    property string apiToken: ""
    property int maxTasks: 50
    property bool busy: statusProcess.running || actionProcess.running
    property string lastError: ""
    property string lastStatus: ""

    readonly property string helperPath: root.pluginDir() + "/openproject.py"
    readonly property string cachePath: Quickshell.env("HOME")
        + "/.local/state/omarchy/openproject-tasks/cache.json"

    function pluginDir() {
        return decodeURIComponent(String(Qt.resolvedUrl("openproject.py")).replace(/^file:\/\//, "").replace(/\/openproject\.py$/, ""))
    }

    signal cacheChanged()
    signal actionDone(bool ok, string message)

    function cleanArgs() {
        return ["--url", root.baseUrl, "--token", root.apiToken,
                "--max", String(root.maxTasks)];
    }

    function refresh() {
        if (root.busy) return
        if (!root.baseUrl || !root.apiToken) return
        root.lastError = ""
        root.lastStatus = "Refreshing..."
        statusProcess.command = ["/usr/bin/python3", root.helperPath, "--out", root.cachePath]
            .concat(root.cleanArgs()).concat(["status"])
        statusProcess.running = true
    }

    function startTimer(workPackageId, comment) {
        if (root.busy) return
        root.lastError = ""
        root.lastStatus = "Starting timer..."
        var cmd = ["/usr/bin/python3", root.helperPath]
            .concat(root.cleanArgs()).concat(["start", String(workPackageId)])
        if (comment !== undefined && comment !== null && String(comment).trim() !== "")
            cmd.push("--comment", String(comment).trim())
        actionProcess.command = cmd
        actionProcess.running = true
    }

    function stopTimer(timeEntryId) {
        if (root.busy) return
        root.lastError = ""
        root.lastStatus = "Stopping timer..."
        var cmd = ["/usr/bin/python3", root.helperPath].concat(root.cleanArgs()).concat(["stop"])
        if (timeEntryId !== undefined && timeEntryId !== null && String(timeEntryId) !== "")
            cmd.push(String(timeEntryId))
        actionProcess.command = cmd
        actionProcess.running = true
    }

    function parseJson(raw) {
        try {
            var v = JSON.parse(String(raw || ""))
            return (v && typeof v === "object") ? v : null
        } catch (e) { return null }
    }

    Process {
        id: statusProcess
        running: false
        stdout: StdioCollector { id: statusOut; waitForEnd: true }
        stderr: StdioCollector { id: statusErr; waitForEnd: true }
        onExited: function(code) {
            var parsed = root.parseJson(statusOut.text)
            if (code === 0 && parsed && parsed.ok === true) {
                root.lastStatus = ""
                root.cacheChanged()
            } else {
                var msg = (parsed && parsed.error) ? String(parsed.error)
                    : String(statusErr.text || "Refresh failed.").replace(/\s+/g, " ").trim()
                root.lastError = msg.length > 220 ? msg.substring(0, 217) + "..." : msg
                root.lastStatus = ""
            }
            root.cacheChanged()
        }
    }

    Process {
        id: actionProcess
        running: false
        stdout: StdioCollector { id: actionOut; waitForEnd: true }
        stderr: StdioCollector { id: actionErr; waitForEnd: true }
        onExited: function(code) {
            var parsed = root.parseJson(actionOut.text)
            var ok = code === 0 && parsed && parsed.ok === true
            var msg
            if (ok) {
                if (parsed.alreadyRunning === true) msg = "Timer already running."
                else if (parsed.stopped !== undefined) msg = parsed.stopped > 0 ? "Timer stopped." : "No timer running."
                else if (parsed.stoppedOthers > 0) msg = "Timer started (previous stopped)."
                else msg = "Timer started."
                root.lastError = ""
                root.lastStatus = msg
            } else {
                msg = (parsed && parsed.error) ? String(parsed.error)
                    : String(actionErr.text || "Action failed.").replace(/\s+/g, " ").trim()
                root.lastError = msg
                root.lastStatus = ""
            }
            root.actionDone(ok, msg)
            Qt.callLater(root.refresh)
        }
    }
}
