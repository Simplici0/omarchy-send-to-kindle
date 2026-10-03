# Send to Kindle

Bar widget for Omarchy Quattro that sends EPUB/PDF files to a `@kindle.com`
address using Amazon's [Send to Kindle by email](https://www.amazon.com/sendtokindle)
over your own SMTP provider. No Calibre, no Docker, no daemons.

## Install

```sh
omarchy plugin add <this-repo-url> --enable
```

Or copy this folder to `~/.config/omarchy/plugins/<your-id>/` and enable it:

```sh
omarchy plugin enable <your-id>
```

Requires: `python3` (stdlib only), `zenity` (native file picker),
`secret-tool` (`libsecret` + `gnome-keyring-daemon`, preinstalled on
Omarchy/Arch).

## Use

1. Click **Kindle** in the bar (or `omarchy-shell shell summon <id> '{}'`).
2. Click **Choose file** and pick an EPUB or PDF (zenity, the native
   system dialog; up to 50 MB — Amazon's per-email limit). Name, format
   and size are shown.
3. Open Settings (⚙): set the Kindle email, then **Show advanced** for
   sender, SMTP host/port and username. Fields save as you type into the
   widget's inline `shell.json` entry.
4. Press **Send to Kindle**. States: ready → sending → sent / error.
   `Escape` closes the panel.

The picker is `zenity` (a normal system toplevel) rather than
`QtQuick.Dialogs`: no built-in layer-shell panel uses `FileDialog`, and
the panel closes before the dialog opens so the dialog owns input. The
`Convert to Kindle format` toggle sets the mail subject to `convert`
(Amazon converts EPUB to Kindle format).

## Configure

Non-secret settings (host, port, user, sender, destination) are edited in
the panel and stored via `persistSettings` in `shell.json`. Nothing secret
is ever stored there, in QML, or in `manifest.json`.

The SMTP secret (password / app-password) lives in gnome-keyring. Store it
once — the panel shows this exact command:

```sh
secret-tool store --label 'Omarchy Send to Kindle' smtp <user>@<host>
```

The helper reads it back itself via `secret-tool lookup`; it never travels
on argv or through QML. If it is missing you get `auth-missing` with the
command to run. If the mail server rejects it you get an actionable
SMTP error, never a stuck panel (60 s timeout rearms to error).

Gmail/Outlook note: plain passwords are usually rejected — create an
**app password** in your provider and store that. OAuth2 is out of scope
for this plugin.

Amazon requirements (on your Amazon account, not in this plugin):

- The **sender** address must be in your Amazon approved-senders list.
- The **destination** must end in `@kindle.com` (or `@free.kindle.com`).
- One file per send; EPUB/PDF only (MOBI/AZW are no longer accepted
  by Amazon email).

## Remove

```sh
omarchy plugin disable <id>   # or: omarchy plugin remove <id> --yes
secret-tool clear smtp <user>@<host>   # forget the stored secret
```

## Security

Unsandboxed by design, like all shell plugins: it runs inside
`omarchy-shell` with your user permissions and opens SMTP connections.
`Process.command` is always a fixed argv array (no `bash -c`
interpolation); audit before enabling, as with any plugin.

## Layout

- `manifest.json` — `bar-widget` contract only, no `panel` kind.
- `BarWidget.qml` — bar button + `Loader` hosting `Panel.qml`.
- `Panel.qml` — picker, metadata, config form, oneshot `Process` + timeout.
- `Model.js` — pure validation/formatting (testable with `node`).
- `helpers/send_kindle.py` — stdlib MIME + SMTP, secret via `secret-tool`.
