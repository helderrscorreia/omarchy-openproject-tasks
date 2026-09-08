#!/usr/bin/env python3
"""OpenProject helper for the Omarchy bar-widget.

All HTTP lives here (stdlib only) so QML never handles secrets directly.
Auth: Basic base64("apikey:<token>").

Commands:
  status                          Fetch open tasks + ongoing timers -> cache.json
  start <workPackageId> [--comment TEXT]   Stop other timers, start new one
  stop [timeEntryId]              Stop given entry or all ongoing timers
  save-token                      Read an API token from stdin and store it in
                                  a private (0600) file; never prints the token
  token-status                    Print {"present": true/false} whether a token
                                  is configured (no secret output)

Common flags: --url, --token, --token-stdin, --token-file, --max, --out, --timeout

The API token is never accepted as a shell argument for request commands; it is
read from the private token file (default
~/.local/state/omarchy/openproject-tasks/token) or from stdin via --token-stdin
(save-token). This keeps the secret out of process command lines.
"""

import argparse
import base64
import datetime
import json
import os
import re
import stat
import sys
import urllib.parse
import urllib.request
import urllib.error


DEFAULT_TOKEN_FILE = os.path.expanduser(
    "~/.local/state/omarchy/openproject-tasks/token")


def token_file_path(explicit):
    if explicit:
        return os.path.expanduser(explicit)
    return DEFAULT_TOKEN_FILE


def read_token_file(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def write_token_file(path, token):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    old_umask = os.umask(0o177)
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(token)
        os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
        os.replace(tmp, path)
    finally:
        os.umask(old_umask)


def resolve_token(args):
    """Return the effective API token without exposing it via argv.

    Priority: --token-stdin > explicit --token > private token file.
    """
    if args.token_stdin:
        line = sys.stdin.readline()
        return line.strip() if line else ""
    if args.token:
        return args.token
    return read_token_file(token_file_path(args.token_file))


MAX_BODY = 2 * 1024 * 1024  # 2 MiB ceiling for any response/error body


def normalize_base(raw):
    """Return a normalized URL, enforcing HTTPS.

    Plain http:// is rejected because the API token is sent with the request;
    the plugin documents HTTPS-only operation. Raises RuntimeError (surfaced as
    a friendly error) when an insecure scheme is given.
    """
    text = (raw or "").strip()
    if not text:
        return ""
    text = text.rstrip("/")
    low = text.lower()
    if low.startswith("http://"):
        raise RuntimeError(
            "Plain-HTTP (http://) URLs are not supported because the API token "
            "would be sent in clear. Use the https:// URL of your OpenProject "
            "instance.")
    if not low.startswith("https://"):
        text = "https://" + text
    return text


def read_capped(fp, limit=MAX_BODY):
    """Read all of fp, aborting once the payload exceeds `limit` bytes."""
    parts = []
    total = 0
    while True:
        chunk = fp.read(8192)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise RuntimeError(
                "Response too large (over {} bytes) and was rejected.".format(limit))
        parts.append(chunk)
    return b"".join(parts)


def reject_oversized_content_length(headers, limit=MAX_BODY):
    """Reject an advertised oversized body before reading it."""
    cl = headers.get("Content-Length")
    if cl is None:
        return
    try:
        if int(cl) > limit:
            raise RuntimeError(
                "Response too large (Content-Length {} > {} bytes) and was "
                "rejected.".format(cl, limit))
    except ValueError:
        pass


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
            reject_oversized_content_length(resp.headers)
            raw = read_capped(resp).decode("utf-8", "replace")
            return resp.status, json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        try:
            reject_oversized_content_length(e.headers)
            detail = read_capped(e).decode("utf-8", "replace")[:500]
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
    token = resolve_token(args)
    if not token:
        fail("No API token configured. Open the widget setup and paste a token from your OpenProject instance.")
    tasks = fetch_tasks(base, token, args.max, args.timeout)
    user_ref, user_name = resolve_user_id(base, token, args.timeout)
    ongoing = fetch_ongoing(base, token, args.timeout, user_ref)
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
    token = resolve_token(args)
    if not base or not token:
        fail("Set openprojectUrl (https) and an API token first.")
    wp_id = str(args.work_package_id)
    user_ref, _ = resolve_user_id(base, token, args.timeout)
    ongoing = fetch_ongoing(base, token, args.timeout, user_ref)
    stopped = 0
    for entry in ongoing:
        if str(entry.get("workPackageId")) == wp_id:
            continue
        api_request(base, token, "PATCH", "/api/v3/time_entries/{}".format(entry["id"]),
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
    activity = default_activity_href(base, token, args.timeout)
    if activity:
        body["_links"]["activity"] = {"href": activity}
    try:
        _, created = api_request(base, token, "POST", "/api/v3/time_entries", body=body, timeout=args.timeout)
    except RuntimeError as e:
        if activity and "activity" in str(e).lower():
            del body["_links"]["activity"]
            _, created = api_request(base, token, "POST", "/api/v3/time_entries", body=body, timeout=args.timeout)
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
    token = resolve_token(args)
    if not base or not token:
        fail("Set openprojectUrl (https) and an API token first.")
    if args.time_entry_id:
        targets = [str(args.time_entry_id)]
    else:
        user_ref, _ = resolve_user_id(base, token, args.timeout)
        targets = [str(e["id"]) for e in fetch_ongoing(base, token, args.timeout, user_ref)]
    if not targets:
        print(json.dumps({"ok": True, "stopped": 0, "message": "No timer running."}))
        return
    for tid in targets:
        ongoing_created = None
        for entry in fetch_ongoing(base, token, args.timeout):
            if str(entry.get("id")) == tid:
                ongoing_created = entry.get("createdAt")
                break
        body = {"ongoing": False, "hours": elapsed_hours(ongoing_created)}
        api_request(base, token, "PATCH", "/api/v3/time_entries/{}".format(tid),
                    body=body, timeout=args.timeout)
    print(json.dumps({"ok": True, "stopped": len(targets)}))


def cmd_save_token(args):
    token = resolve_token(args)  # --token-stdin reads from stdin
    if not token:
        fail("No token provided on stdin.")
    write_token_file(token_file_path(args.token_file), token)
    print(json.dumps({"ok": True}))


def cmd_token_status(args):
    present = read_token_file(token_file_path(args.token_file)) != ""
    print(json.dumps({"ok": True, "present": present}))


def fail(message):
    print(json.dumps({"ok": False, "error": message}))
    sys.exit(1)


def main():
    p = argparse.ArgumentParser(description="OpenProject helper for Omarchy plugin")
    p.add_argument("--url", default="", help="OpenProject base URL")
    p.add_argument("--token", default="", help="API token (override; prefer --token-file or stdin)")
    p.add_argument("--token-stdin", action="store_true", help="Read the API token from the first stdin line")
    p.add_argument("--token-file", default="", help="Private file holding the API token")
    p.add_argument("--max", type=int, default=50)
    p.add_argument("--out", default="", help="cache.json path for status")
    p.add_argument("--timeout", type=int, default=20)
    sub = p.add_subparsers(dest="cmd")
    sub.add_parser("status")
    sub.add_parser("save-token")
    sub.add_parser("token-status")
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
        elif args.cmd == "save-token":
            cmd_save_token(args)
        elif args.cmd == "token-status":
            cmd_token_status(args)
        else:
            cmd_status(args)
    except RuntimeError as e:
        fail(str(e))
    except Exception as e:
        fail("{}: {}".format(type(e).__name__, e))


if __name__ == "__main__":
    main()
