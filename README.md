# OpenProject Tasks — Omarchy bar-widget

Bar widget that shows your **open assigned OpenProject work packages**, their **priorities**, and the **currently timed task**, with **start/stop timer** and **comment labels** on time entries. A panel lists tasks sorted by priority with search, per-task Start/Switch/Stop, and a **+ New task** button.

## Features

- Orange `⏱ <count>` bar icon; a `●` accent dot appears while a timer is running.
- Click the icon to open the panel.
- Tasks sorted by priority (custom "Very High" supported) with status colors.
- Start / Switch / Stop the timer per task, with a **comment label** kept on the time entry.
- Search box to filter tasks (subject, id, project, status, type, priority).
- `+ New task` opens OpenProject's create-work-package page in your browser.
- Only sends authenticated HTTPS requests to the OpenProject instance you configure.

## Install

```sh
omarchy plugin add https://github.com/helderrscorreia/omarchy-openproject-tasks.git --enable
```

## Configure

Click the widget in the bar → gear icon to open Setup. Enter your instance URL, an API token, and optionally a custom bar label.

- **URL**: base URL of your instance, e.g. `https://projects.example.com` (no trailing `/api`).
- **API token**: My account → Access tokens → `+ API Token`. The `+ API token` button in Setup opens `<url>/my/access_tokens`. The token is sent as HTTP Basic auth `apikey:<token>`.
- **Bar label** (optional): text shown in the bar next to the icon and in the panel header. Defaults to `OpenProject Tasks`.

The instance URL and bar label are stored in your user's Omarchy shell settings. The API token is stored in a **private file** (`~/.local/state/omarchy/openproject-tasks/token`, mode `0600`) — it is never placed in process command lines, never committed, and never sent anywhere except as Basic auth to the configured instance.

## Usage

- **Open / close**: left-click the bar icon.
- **Start**: select a task and press Start (other running timers are auto-stopped). Add a comment; the comment is stored on the time entry.
- **Stop**: press Stop on the active task, or it stops all ongoing timers.
- **New task**: header `+ New task` opens the create-work-package page in the browser.

## Remove

```sh
omarchy plugin remove helderrscorreia.openproject-tasks
```

## How it works

- `openproject.py` (Python 3 stdlib only) does all HTTP with `Authorization: Basic base64("apikey:<token>")`.
- `--status`: fetches open work packages assigned to you + ongoing time entries → cache.
- `--start <wpId> --comment "..."`: auto-stops other timers, creates a new ongoing time entry with a comment.
- `--stop [id]`: stops the given entry or all ongoing timers.
- `BarWidget.qml` renders the bar icon and loads the panel.
- `Panel.qml` lists tasks, search, timer controls, and the create-task button.
- `OpenProjectModel.js` computes priority ordering and status/priority colors.

## Security

This plugin runs unsandboxed inside the long-running Omarchy shell process. It makes authenticated HTTPS requests only to the OpenProject URL you configure (plain `http://` is refused so the token is never sent in clear), spawns `/usr/bin/python3` (stdlib only, no network access beyond the configured instance), and stores your API token in a private `0600` file (`~/.local/state/omarchy/openproject-tasks/token`), reading it over stdin/from the file so the secret never appears in a process command line. Review the source before installing.

## License

[MIT](LICENSE)
