.pragma library

function normalizeBaseUrl(raw) {
    var text = String(raw || "").trim().replace(/\s+/g, "");
    text = text.replace(/\/+$/, "");
    if (text.length > 0 && text.indexOf("http://") !== 0 && text.indexOf("https://") !== 0)
        text = "https://" + text;
    return text;
}

function tokenUrlFor(baseUrl) {
    var base = normalizeBaseUrl(baseUrl);
    if (!base) return "";
    return base + "/my/access_tokens";
}

function isValidBase(baseUrl) {
    return normalizeBaseUrl(baseUrl) !== "";
}

var PRIORITY_RANK = {
    "immediate": 0,
    "urgent": 1,
    "very high": 2,
    "high": 3,
    "normal": 4,
    "low": 5
};

// Anything not an exact priority name maps to this. Junk/unranked should sit
// below the real priorities but above a truly unknown fallback, so bar order
// stays sensible and stable.
var PRIORITY_UNKNOWN = 99;

function priorityRank(title) {
    var key = String(title || "").toLowerCase().trim();
    if (PRIORITY_RANK.hasOwnProperty(key)) return PRIORITY_RANK[key];
    return PRIORITY_UNKNOWN;
}

function compareTasks(a, b) {
    var ra = priorityRank(a && a.priority), rb = priorityRank(b && b.priority);
    if (ra !== rb) return ra - rb;
    var ua = Date.parse(a && a.updatedAt ? a.updatedAt : ""), ub = Date.parse(b && b.updatedAt ? b.updatedAt : "");
    if (!isNaN(ua) && !isNaN(ub) && ua !== ub) return ub - ua;
    var ia = (a && a.id) || 0, ib = (b && b.id) || 0;
    return ia - ib;
}

function sortedTasks(tasks) {
    var result = (tasks || []).slice();
    result.sort(compareTasks);
    return result;
}

function priorityColor(title, fallback) {
    var key = String(title || "").toLowerCase().trim();
    if (key === "immediate" || key === "urgent") return "#e5484d";
    if (key === "high") return "#e0af68";
    if (key === "low") return "#8b8d98";
    return fallback || "#4caf50";
}

// Status -> readable foreground color used to highlight the task's status line.
// Falls back to the muted foreground when the status is unrecognized.
function statusColor(status) {
    var key = String(status || "").toLowerCase().trim();
    if (key === "new" || key === "in progress" || key === "in development") return "#4caf50";
    if (key === "on hold" || key === "blocked" || key === "waiting") return "#e0af68";
    if (key === "closed" || key === "done" || key === "resolved" || key === "completed") return "#8b8d98";
    if (key === "rejected" || key === "cancelled" || key === "rejected - duplicated") return "#e5484d";
    if (key === "bill pending" || key.indexOf("bill") === 0) return "#3b82f6";
    return null;
}

function elapsedLabel(startedAt, nowMs) {
    var start = Date.parse(startedAt || "");
    if (isNaN(start)) return "";
    var s = Math.max(0, Math.floor(((nowMs || Date.now()) - start) / 1000));
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
    if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m";
    if (m > 0) return m + "m " + (s % 60) + "s";
    return s + "s";
}

function shortError(message, fallback) {
    var text = String(message || "").replace(/\s+/g, " ").trim();
    if (!text) text = fallback || "Request failed.";
    return text.length > 220 ? text.substring(0, 217) + "..." : text;
}
