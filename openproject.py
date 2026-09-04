#!/usr/bin/env python3
"""OpenProject helper for the Omarchy bar-widget.

All HTTP lives here (stdlib only) so QML never handles secrets directly.
Auth: Basic base64("apikey:<token>").

Commands:
  status                          Fetch open tasks + ongoing timers -> cache.json
  start <workPackageId> [--comment TEXT]   Stop other timers, start new one
  stop [timeEntryId]              Stop given entry or all ongoing timers

Common flags: --url, --token, --max, --out, --timeout
"""

import argparse
import base64
import datetime
import json
import os
import re
import sys
import urllib.parse
import urllib.request
import urllib.error


def normalize_base(raw):
    text = (raw or "").strip()
    text = text.rstrip("/")
    if text and not text.startswith("http://") and not text.startswith("https://"):
        text = "https://" + text
    return text


def auth_headers(token):
    creds = "apikey:{}".format(token or "").encode("utf-8")
    basic = base64.b64encode(creds).decode("ascii")
    return {
        "Authorization": "Basic " + basic,
        "Accept": "application/hal+json",
        "Content-Type": "application/json",
        "User-Agent": "omarchy-openproject-tasks/1.0.0",
    }


def api_request(base, token, method, path, params=None, body=None, timeout=20):
    url = base + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=auth_headers(token))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            return resp.status, json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        try:
            detail = e.read().decode("utf-8", "replace")[:500]
        except Exception:
            detail = ""
        raise RuntimeError(friendly_http_error(e.code, path, detail or str(e.reason), base))
    except urllib.error.URLError as e:
        reason = str(getattr(e, "reason", e))
        if "CERTIFICATE" in reason.upper() or "SSL" in reason.upper():
            raise RuntimeError(
                "SSL error for {} ({}). Self-signed cert? Import your CA.".format(path, reason))
        raise RuntimeError("Network error for {}: {}. Check the instance URL.".format(path, reason))


def strip_html(text):
    return " ".join(re.sub(r"<[^>]+>", " ", text or "").split())


def friendly_http_error(code, path, detail, base):
    detail = strip_html(detail)
    server_msg = ""
    try:
        parsed = json.loads(detail) if detail.startswith("{") else None
        if isinstance(parsed, dict) and parsed.get("message"):
            server_msg = str(parsed["message"])[:200]
    except Exception:
        pass
    if code in (401, 403):
        return ("Access denied (HTTP {}). Invalid or expired API token. "
                "Generate a new one at {}/my/access_tokens.").format(code, base)
    if code == 404:
        return "Not found (HTTP 404) at {}. Check the instance URL (no trailing /api).".format(path)
    if server_msg:
        return "HTTP {} {}: {}".format(code, path, server_msg)
    if detail:
        return "HTTP {} {}: {}".format(code, path, detail[:200])
    return "HTTP {} {}.".format(code, path)


def link_id(link):
    href = ((link or {}).get("href") or "")
    parts = href.rstrip("/").split("/")
    return parts[-1] if parts else ""


def resolve_user_id(base, token, timeout):
    try:
        _, payload = api_request(base, token, "GET", "/api/v3/users/me", timeout=timeout)
        uid = payload.get("id")
        if isinstance(uid, int) and uid > 0:
            return str(uid), payload.get("name") or ""
    except Exception:
        pass
    return "me", ""


def fetch_tasks(base, token, max_tasks, timeout):
    filters = json.dumps([
        {"assigneeOrGroup": {"operator": "=", "values": ["me"]}},
        {"status": {"operator": "o", "values": []}},
    ])
    _, payload = api_request(base, token, "GET", "/api/v3/work_packages", params={
        "filters": filters,
        "sortBy": json.dumps([["priority", "asc"], ["updatedAt", "desc"]]),
        "pageSize": max(1, min(int(max_tasks or 50), 200)),
    }, timeout=timeout)
    tasks = []
    for el in (payload.get("_embedded") or {}).get("elements") or []:
        links = el.get("_links") or {}
        tasks.append({
            "id": el.get("id"),
            "subject": el.get("subject") or "(no subject)",
            "priority": ((links.get("priority") or {}).get("title")) or "",
            "status": ((links.get("status") or {}).get("title")) or "",
            "type": ((links.get("type") or {}).get("title")) or "",
            "project": ((links.get("project") or {}).get("title")) or "",
            "updatedAt": el.get("updatedAt") or "",
            "href": ((links.get("self") or {}).get("href")) or "",
        })
    return tasks


def fetch_ongoing(base, token, timeout, user_ref="me"):
    filters = json.dumps([
        {"user_id": {"operator": "=", "values": [user_ref]}},
        {"ongoing": {"operator": "=", "values": ["t"]}},
    ])
    _, payload = api_request(base, token, "GET", "/api/v3/time_entries", params={
        "filters": filters,
        "pageSize": 10,
    }, timeout=timeout)
    entries = (payload.get("_embedded") or {}).get("elements") or []
    result = []
    for e in entries:
        links = e.get("_links") or {}
        entity = links.get("entity") or {}
        comment_obj = e.get("comment") or {}
        comment_raw = comment_obj.get("raw") if isinstance(comment_obj, dict) else (e.get("comment") or "")
        result.append({
            "id": e.get("id"),
            "comment": comment_raw or "",
            "spentOn": e.get("spentOn") or "",
            "createdAt": e.get("createdAt") or "",
            "workPackageId": link_id(entity),
            "workPackageTitle": entity.get("title") or "",
        })
    return result


def default_activity_href(base, token, timeout):
    try:
        _, payload = api_request(base, token, "GET", "/api/v3/time_entries/activities", timeout=timeout)
        elements = (payload.get("_embedded") or {}).get("elements") or []
        if elements:
            href = ((elements[0].get("_links") or {}).get("self") or {}).get("href")
            if href:
                return href
    except Exception:
        pass
    return None


def cmd_status(args):
    base = normalize_base(args.url)
    if not base:
        fail("Set your OpenProject URL first (omarchy bar set helderrscorreia.openproject-tasks openprojectUrl https://...).")
    if not args.token:
        fail("Set your API token first (omarchy bar set helderrscorreia.openproject-tasks apiToken <token>).")
    tasks = fetch_tasks(base, args.token, args.max, args.timeout)
    user_ref, user_name = resolve_user_id(base, args.token, args.timeout)
    ongoing = fetch_ongoing(base, args.token, args.timeout, user_ref)
    cache = {
        "schemaVersion": 1,
        "fetchedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "baseUrl": base,
        "userName": user_name,
        "tasks": tasks,
        "ongoing": ongoing,
        "error": "",
    }
    if args.out:
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        tmp = args.out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cache, f, indent=2)
            f.write("\n")
        os.replace(tmp, args.out)
    print(json.dumps({"ok": True, "tasks": len(tasks), "ongoing": len(ongoing)}))


def cmd_start(args):
    base = normalize_base(args.url)
    if not base or not args.token:
        fail("Set openprojectUrl and apiToken first.")
    wp_id = str(args.work_package_id)
    user_ref, _ = resolve_user_id(base, args.token, args.timeout)
    ongoing = fetch_ongoing(base, args.token, args.timeout, user_ref)
    stopped = 0
    for entry in ongoing:
        if str(entry.get("workPackageId")) == wp_id:
            continue
        api_request(base, args.token, "PATCH", "/api/v3/time_entries/{}".format(entry["id"]),
                    body={"ongoing": False}, timeout=args.timeout)
        stopped += 1
    for entry in ongoing:
        if str(entry.get("workPackageId")) == wp_id:
            print(json.dumps({"ok": True, "alreadyRunning": True, "timeEntryId": entry["id"], "stoppedOthers": stopped}))
            return
    today = datetime.date.today().isoformat()
    body = {
        "_links": {"entity": {"href": "/api/v3/work_packages/{}".format(wp_id)}},
        "spentOn": today,
        "hours": "PT0S",
        "ongoing": True,
    }
    comment = (args.comment or "").strip()
    if comment:
        body["comment"] = {"raw": comment}
    activity = default_activity_href(base, args.token, args.timeout)
    if activity:
        body["_links"]["activity"] = {"href": activity}
    try:
        _, created = api_request(base, args.token, "POST", "/api/v3/time_entries", body=body, timeout=args.timeout)
    except RuntimeError as e:
        if activity and "activity" in str(e).lower():
            del body["_links"]["activity"]
            _, created = api_request(base, args.token, "POST", "/api/v3/time_entries", body=body, timeout=args.timeout)
        else:
            raise
    print(json.dumps({"ok": True, "timeEntryId": created.get("id"), "stoppedOthers": stopped}))


def elapsed_hours(created_at, fallback="PT0S"):
    """ISO-8601 duration of wall-clock time between createdAt and now.

    OpenProject rejects stopping an ongoing entry whose 'hours' is blank, so we
    must send the elapsed duration on the stop PATCH. Falls back to PT0S when
    the created timestamp is missing/unparsable.
    """
    try:
        start = datetime.datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        now = datetime.datetime.now(datetime.timezone.utc)
        delta = max(0, int((now - start).total_seconds()))
    except Exception:
        return fallback
    if delta <= 0:
        return fallback
    hours, rem = divmod(delta, 3600)
    minutes, seconds = divmod(rem, 60)
    if hours == 0 and minutes == 0:
        return "PT{}S".format(seconds)
    return "PT{}H{}M{}S".format(hours, minutes, seconds)


def cmd_stop(args):
    base = normalize_base(args.url)
    if not base or not args.token:
        fail("Set openprojectUrl and apiToken first.")
    if args.time_entry_id:
        targets = [str(args.time_entry_id)]
    else:
        user_ref, _ = resolve_user_id(base, args.token, args.timeout)
        targets = [str(e["id"]) for e in fetch_ongoing(base, args.token, args.timeout, user_ref)]
    if not targets:
        print(json.dumps({"ok": True, "stopped": 0, "message": "No timer running."}))
        return
    for tid in targets:
        ongoing_created = None
        for entry in fetch_ongoing(base, args.token, args.timeout):
            if str(entry.get("id")) == tid:
                ongoing_created = entry.get("createdAt")
                break
        body = {"ongoing": False, "hours": elapsed_hours(ongoing_created)}
        api_request(base, args.token, "PATCH", "/api/v3/time_entries/{}".format(tid),
                    body=body, timeout=args.timeout)
    print(json.dumps({"ok": True, "stopped": len(targets)}))


def fail(message):
    print(json.dumps({"ok": False, "error": message}))
    sys.exit(1)


def main():
    p = argparse.ArgumentParser(description="OpenProject helper for Omarchy plugin")
    p.add_argument("--url", default="", help="OpenProject base URL")
    p.add_argument("--token", default="", help="API token")
    p.add_argument("--max", type=int, default=50)
    p.add_argument("--out", default="", help="cache.json path for status")
    p.add_argument("--timeout", type=int, default=20)
    sub = p.add_subparsers(dest="cmd")
    sub.add_parser("status")
    s = sub.add_parser("start")
    s.add_argument("work_package_id")
    s.add_argument("--comment", default="", help="Comment label for the time entry")
    t = sub.add_parser("stop")
    t.add_argument("time_entry_id", nargs="?")
    args = p.parse_args()
    try:
        if args.cmd == "start":
            cmd_start(args)
        elif args.cmd == "stop":
            cmd_stop(args)
        else:
            cmd_status(args)
    except RuntimeError as e:
        fail(str(e))
    except Exception as e:
        fail("{}: {}".format(type(e).__name__, e))


if __name__ == "__main__":
    main()
