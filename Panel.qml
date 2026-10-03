import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Send to Kindle popup: pick an EPUB/PDF, review metadata, configure
// SMTP + destination once, and send via helpers/send_kindle.py.
//
// The secret (SMTP password / app-password) is never stored here: it lives
// in gnome-keyring and is read inside the helper via `secret-tool lookup`.
// Non-secret config persists in the widget's inline shell.json entry.
Panel {
  id: root
  moduleName: "local.send-to-kindle"
  ipcTarget: "local.send-to-kindle"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- file selection (path entry; see README for FileDialog decision)
  property string filePath: ""
  property string fileSizeText: "—"
  readonly property string fileName: filePath === "" ? "" : String(filePath).split("/").pop()
  readonly property string fileFormat: filePath === "" ? "" : Model.formatLabel(filePath)
  readonly property var fileCheck: Model.validateFile(filePath, fileSizeBytes)
  property double fileSizeBytes: -1

  // ---- non-secret config (persisted inline in shell.json)
  readonly property string smtpHost: setting("smtpHost", "")
  readonly property int smtpPort: Number(setting("smtpPort", 587)) || 587
  readonly property string smtpUser: setting("smtpUser", "")
  readonly property string fromEmail: setting("fromEmail", "")
  readonly property string toEmail: setting("toEmail", "")
  readonly property bool convert: setting("convert", true) !== false

  // ---- send state machine: ready | sending | sent | error
  property string sendState: Model.STATUS_READY
  property string statusText: "Choose a file to begin."
  property string lastSentAt: ""
  readonly property bool sending: sendState === Model.STATUS_SENDING

  readonly property string scriptPath:
    Qt.resolvedUrl("helpers/send_kindle.py").toString().replace(/^file:\/\//, "")

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function open() {
    refreshDefaults()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function saveField(key, value) {
    var values = {}
    values[key] = value
    persistSettings(values)
  }

  function refreshDefaults() {
    hostField.text = root.smtpHost
    portField.text = String(root.smtpPort)
    userField.text = root.smtpUser
    fromField.text = root.fromEmail
    toField.text = root.toEmail
  }

  function storeSecretCommand() {
    return "secret-tool store --label 'Omarchy Send to Kindle' smtp " + root.smtpUser + "@" + root.smtpHost
  }

  // Resolve the picked path to a size for display + pre-flight validation.
  function pickFile(path) {
    var trimmed = String(path || "").trim()
    root.filePath = trimmed
    root.sendState = Model.STATUS_READY
    if (trimmed === "") {
      root.fileSizeBytes = -1
      root.fileSizeText = "—"
      root.statusText = "Choose a file to begin."
      return
    }
    sizeProc.command = ["stat", "-c", "%s", trimmed]
    sizeProc.running = true
  }

  function currentConfig() {
    return {
      smtpHost: hostField.text.trim(),
      smtpPort: Number(portField.text),
      smtpUser: userField.text.trim(),
      fromEmail: fromField.text.trim(),
      toEmail: toField.text.trim()
    }
  }

  function send() {
    if (sendProc.running) return
    var cfg = currentConfig()
    var cfgCheck = Model.validateConfig(cfg)
    if (!cfgCheck.ok) {
      root.sendState = Model.STATUS_ERROR
      root.statusText = Model.errorMessage(cfgCheck.error)
      return
    }
    persistSettings({
      smtpHost: cfg.smtpHost,
      smtpPort: cfg.smtpPort,
      smtpUser: cfg.smtpUser,
      fromEmail: cfg.fromEmail,
      toEmail: cfg.toEmail,
      convert: convertSwitch.checked
    })
    var size = Number(root.fileSizeBytes)
    var check = Model.validateFile(root.filePath, isFinite(size) && size >= 0 ? size : undefined)
    if (!check.ok) {
      root.sendState = Model.STATUS_ERROR
      root.statusText = Model.errorMessage(check.error)
      return
    }
    var subject = convertSwitch.checked ? "convert" : "kindle"
    sendProc.command = [
      "python3", root.scriptPath,
      "--smtp-host", cfg.smtpHost,
      "--smtp-port", String(cfg.smtpPort),
      "--smtp-user", cfg.smtpUser,
      "--from", cfg.fromEmail,
      "--to", cfg.toEmail.trim().toLowerCase(),
      "--file", root.filePath,
      "--subject", subject
    ]
    root.sendState = Model.STATUS_SENDING
    root.statusText = "Sending…"
    sendProc.running = true
    sendTimeout.restart()
  }

  function finishSend(exitCode, output) {
    sendTimeout.stop()
    var line = String(output || "").trim()
    if (exitCode === 0 && line.startsWith("OK")) {
      root.sendState = Model.STATUS_SENT
      root.lastSentAt = new Date().toLocaleTimeString()
      root.statusText = "Sent to " + currentConfig().toEmail + " at " + root.lastSentAt + "."
    } else {
      root.sendState = Model.STATUS_ERROR
      root.statusText = sendErrorMessage(line)
    }
  }

  function sendErrorMessage(line) {
    if (line.startsWith("ERROR auth-missing"))
      return "SMTP secret not in keyring. Run: " + storeSecretCommand()
    if (line.startsWith("ERROR smtp-auth"))
      return "SMTP rejected the credentials. Check the app-password, then retry."
    if (line.startsWith("ERROR smtp-error"))
      return "SMTP error: " + line.slice("ERROR smtp-error".length).trim()
    if (line.startsWith("ERROR too-large"))
      return Model.errorMessage("too-large")
    if (line.startsWith("ERROR unsupported-type"))
      return Model.errorMessage("unsupported-type")
    if (line.startsWith("ERROR no-such-file"))
      return "File not found. Pick it again."
    if (line.startsWith("ERROR bad-to"))
      return Model.errorMessage("bad-to")
    if (line !== "") return line
    return "Send failed with no message."
  }

  // Reads the picked file's size without blocking the panel.
  Process {
    id: sizeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var n = Number(String(text).trim())
        if (!isFinite(n) || n < 0) {
          root.fileSizeBytes = -1
          root.fileSizeText = "—"
          root.sendState = Model.STATUS_ERROR
          root.statusText = Model.errorMessage("bad-size")
          return
        }
        root.fileSizeBytes = n
        root.fileSizeText = Model.formatBytes(n)
        var check = Model.validateFile(root.filePath, n)
        if (!check.ok) {
          root.sendState = Model.STATUS_ERROR
          root.statusText = Model.errorMessage(check.error)
        } else {
          root.sendState = Model.STATUS_READY
          root.statusText = "Ready to send."
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.fileSizeBytes = -1
        root.fileSizeText = "—"
        root.sendState = Model.STATUS_ERROR
        root.statusText = "File not found. Pick it again."
      }
    }
  }

  // Oneshot send: stdout carries the OK/ERROR line, onExited flips state.
  Process {
    id: sendProc
    stdout: StdioCollector {
      id: sendStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: sendStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.finishSend(exitCode, sendStdout.text)
    }
  }

  // Safety net: a wedged SMTP handshake must not pin the panel on "Sending…".
  Timer {
    id: sendTimeout
    interval: 60000
    repeat: false
    onTriggered: {
      if (!root.sending) return
      root.sendState = Model.STATUS_ERROR
      root.statusText = "Timed out waiting for the mail server. Check network and retry."
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: pathField.activeFocus || hostField.activeFocus || portField.activeFocus
        || userField.activeFocus || fromField.activeFocus || toField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: {
        if (root.sendState !== Model.STATUS_SENDING) root.send()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: column.width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        ColumnLayout {
          id: column
          width: Math.max(parent.width, Style.space(420))
          spacing: Style.spacing.controlGap

          Text {
            text: "Send to Kindle"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.controlGap

            TextField {
              id: pathField
              Layout.fillWidth: true
              placeholderText: "/home/user/books/novel.epub"
              text: root.filePath
              font.family: root.contentFontFamily
              foreground: root.contentForeground
              Keys.onReturnPressed: root.pickFile(text)
              onAccepted: root.pickFile(text)
            }

            Button {
              text: "Pick"
              focusable: true
              onClicked: root.pickFile(pathField.text)
            }
          }
          Text {
            text: "Paste the file path, then Pick. EPUB or PDF, up to 50 MB."
            color: root.contentForeground
            opacity: 0.7
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            Layout.fillWidth: true
          }

          Text {
            text: root.fileName === "" ? "No file selected."
              : root.fileName + "  ·  " + root.fileFormat + "  ·  " + root.fileSizeText
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            Layout.fillWidth: true
          }

          TextField {
            id: toField
            Layout.fillWidth: true
            placeholderText: "you@kindle.com"
            font.family: root.contentFontFamily
            foreground: root.contentForeground
            onEditingFinished: root.saveField("toEmail", text.trim())
          }
          TextField {
            id: fromField
            Layout.fillWidth: true
            placeholderText: "Approved sender email"
            font.family: root.contentFontFamily
            foreground: root.contentForeground
            onEditingFinished: root.saveField("fromEmail", text.trim())
          }
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.controlGap
            TextField {
              id: hostField
              Layout.fillWidth: true
              placeholderText: "smtp.gmail.com"
              font.family: root.contentFontFamily
              foreground: root.contentForeground
              onEditingFinished: root.saveField("smtpHost", text.trim())
            }
            TextField {
              id: portField
              Layout.preferredWidth: Style.space(80)
              placeholderText: "587"
              inputMethodHints: Qt.ImhDigitsOnly
              font.family: root.contentFontFamily
              foreground: root.contentForeground
              onEditingFinished: root.saveField("smtpPort", Number(text) || 587)
            }
          }
          TextField {
            id: userField
            Layout.fillWidth: true
            placeholderText: "SMTP username"
            font.family: root.contentFontFamily
            foreground: root.contentForeground
            onEditingFinished: root.saveField("smtpUser", text.trim())
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.controlGap
            Text {
              text: "Convert to Kindle format"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }
            ToggleSwitch {
              id: convertSwitch
              checked: root.convert
              foreground: root.contentForeground
              onToggled: root.persistSettings({ convert: !checked })
            }
          }

          Text {
            text: "Secret (one-time setup):\n" + root.storeSecretCommand()
            color: root.contentForeground
            opacity: 0.7
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            Layout.fillWidth: true
          }

          Button {
            Layout.fillWidth: true
            focusable: true
            enabled: !root.sending && root.filePath !== ""
            text: root.sending ? "Sending…" : "Send to Kindle"
            onClicked: root.send()
          }

          Text {
            text: root.statusText
            color: root.sendState === Model.STATUS_ERROR ? Color.urgent : root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            font.bold: root.sendState === Model.STATUS_SENT
            wrapMode: Text.Wrap
            Layout.fillWidth: true
          }
        }
      }
    }
  }
}
