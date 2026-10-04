import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Send to Kindle popup: minimal main view (hero + file card + To line +
// Send + one status line) with technical config tucked into Settings.
//
// The secret (SMTP password / app-password) is never stored here: it lives
// in gnome-keyring and is read inside the helper via `secret-tool lookup`.
// Non-secret config persists in the widget's inline shell.json entry.
Panel {
  id: root
  moduleName: "io.github.simplici0.send-to-kindle"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- navigation: main view vs settings view
  property bool showSettings: false
  property bool showAdvanced: false

  // ---- file selection (Choose file only; see README for FileDialog decision)
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

  // Gate for the Send button: non-secret config must validate (secret itself
  // is checked at send time by the helper, never stored here).
  readonly property bool configured: Model.validateConfig({
    smtpHost: root.smtpHost,
    smtpPort: root.smtpPort,
    smtpUser: root.smtpUser,
    fromEmail: root.fromEmail,
    toEmail: root.toEmail
  }).ok

  // ---- send state machine: ready | sending | sent | error
  property string sendState: Model.STATUS_READY
  property string statusText: "Choose a file to begin."
  property string lastSentAt: ""
  readonly property bool sending: sendState === Model.STATUS_SENDING

  // ---- keyring secret presence (boolean only, never the secret)
  property string secretState: "unknown"

  // True when the send timeout fired: the process was killed and its exit
  // must not overwrite the timeout message with a generic failure.
  property bool sendTimedOut: false

  // Last keyring-store note shown under the secret row (never the secret).
  property string secretNote: ""

  readonly property string scriptPath:
    decodeURIComponent(Qt.resolvedUrl("helpers/send_kindle.py").toString().replace(/^file:\/\//, ""))

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dimmed: Qt.darker(contentForeground, 1.55)

  function open() {
    root.showSettings = false
    root.controller.show()
  }

  function close() {
    flushPendingFields()
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

  // Settings commit: while Settings is open, the field text is the live
  // truth. Persisting is debounced off typing, not focus loss — a click on a
  // button never blurs a text field, so waiting for editingFinished alone can
  // leave the persisted snapshot (and any gate reading it) stuck stale.
  function commitFields() {
    persistSettings({
      toEmail: toField.text.trim(),
      fromEmail: fromField.text.trim(),
      smtpHost: hostField.text.trim(),
      smtpPort: Number(portField.text) || 587,
      smtpUser: userField.text.trim()
    })
  }

  // The commit timer's running state doubles as the dirty flag: there is
  // nothing to flush unless the user typed since the last commit.
  function flushPendingFields() {
    if (!settingsCommit.running) return
    settingsCommit.stop()
    commitFields()
  }

  function onSettingsFieldEdited() {
    if (!root.showSettings) return
    settingsCommit.restart()
  }

  // The key inputs also re-check the keyring once they settle.
  function onKeyFieldEdited() {
    if (!root.showSettings) return
    settingsCommit.restart()
    secretRecheck.restart()
  }

  function refreshSettingsFields() {
    if (toField.activeFocus || fromField.activeFocus || hostField.activeFocus
        || portField.activeFocus || userField.activeFocus) return
    toField.text = root.toEmail
    fromField.text = root.fromEmail
    hostField.text = root.smtpHost
    portField.text = String(root.smtpPort)
    userField.text = root.smtpUser
  }

  function openSettings() {
    refreshSettingsFields()
    if (root.smtpUser === "" || root.smtpHost === "") root.showAdvanced = true
    root.showSettings = true
    root.verifySecret()
  }

  function closeSettings() {
    flushPendingFields()
    root.showSettings = false
    // The focused field turns invisible with the view; hand focus back to the
    // key catcher so Escape/Send keep working without reopening the panel.
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Live values while Settings is open, persisted values otherwise.
  function effectiveSmtpUser() {
    return root.showSettings ? userField.text.trim() : root.smtpUser
  }

  function effectiveSmtpHost() {
    return root.showSettings ? hostField.text.trim() : root.smtpHost
  }

  // Store the pasted app-password in the keyring: the secret travels to the
  // helper over stdin (never argv), matching the shell's own credential flow.
  function storeSecret() {
    if (storeSecretProc.running) return
    flushPendingFields()
    if (root.smtpUser === "" || root.smtpHost === "" || secretField.text === "") return
    root.secretNote = ""
    storeSecretProc.command = [
      "python3", root.scriptPath,
      "--store-secret",
      "--smtp-user", root.smtpUser,
      "--smtp-host", root.smtpHost
    ]
    storeSecretProc.running = true
  }

  // Verify keyring presence via the helper (prints OK/MISSING, exit 0).
  // The secret itself never enters QML, stdout text, or logs.
  function verifySecret() {
    flushPendingFields()
    if (root.smtpUser === "" || root.smtpHost === "") {
      root.secretState = "unconfigured"
      return
    }
    secretProc.command = [
      "python3", root.scriptPath,
      "--check-secret",
      "--smtp-user", root.smtpUser,
      "--smtp-host", root.smtpHost
    ]
    root.secretState = "checking"
    secretProc.running = true
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

  function clearFile() {
    root.filePath = ""
    root.fileSizeBytes = -1
    root.fileSizeText = "—"
    root.sendState = Model.STATUS_READY
    root.statusText = "Choose a file to begin."
  }

  function sendButtonText() {
    if (root.sending) return "Sending…"
    if (root.sendState === Model.STATUS_ERROR) return "Retry"
    return "Send to Kindle"
  }

  function send() {
    if (sendProc.running) return
    flushPendingFields()
    root.sendTimedOut = false
    var cfg = {
      smtpHost: root.smtpHost,
      smtpPort: root.smtpPort,
      smtpUser: root.smtpUser,
      fromEmail: root.fromEmail,
      toEmail: root.toEmail
    }
    var cfgCheck = Model.validateConfig(cfg)
    if (!cfgCheck.ok) {
      root.sendState = Model.STATUS_ERROR
      root.statusText = Model.errorMessage(cfgCheck.error)
      return
    }
    var size = Number(root.fileSizeBytes)
    var check = Model.validateFile(root.filePath, isFinite(size) && size >= 0 ? size : undefined)
    if (!check.ok) {
      root.sendState = Model.STATUS_ERROR
      root.statusText = Model.errorMessage(check.error)
      return
    }
    sendProc.command = [
      "python3", root.scriptPath,
      "--smtp-host", cfg.smtpHost,
      "--smtp-port", String(cfg.smtpPort),
      "--smtp-user", cfg.smtpUser,
      "--from", cfg.fromEmail,
      "--to", cfg.toEmail.trim().toLowerCase(),
      "--file", root.filePath,
      "--subject", root.convert ? "convert" : "kindle"
    ]
    root.sendState = Model.STATUS_SENDING
    root.statusText = "Sending " + root.fileName + "…"
    sendProc.running = true
    sendTimeout.restart()
  }

  function finishSend(exitCode, output) {
    sendTimeout.stop()
    if (root.sendTimedOut) return
    var line = String(output || "").trim()
    if (exitCode === 0 && line.startsWith("OK")) {
      root.sendState = Model.STATUS_SENT
      root.lastSentAt = new Date().toLocaleTimeString()
      root.statusText = "Sent to " + root.toEmail + " · " + root.lastSentAt + "."
    } else {
      root.sendState = Model.STATUS_ERROR
      root.statusText = sendErrorMessage(line)
    }
  }

  function sendErrorMessage(line) {
    if (line.startsWith("ERROR auth-missing"))
      return "SMTP secret not in keyring. Open Settings to fix it."
    if (line.startsWith("ERROR smtp-auth"))
      return "SMTP rejected the credentials. Check the app-password, then retry."
    if (line.startsWith("ERROR smtp-error")) {
      var detail = line.slice("ERROR smtp-error".length).trim()
      if (/timed out|unexpectedly closed|refused/i.test(detail))
        return "Could not reach the mail server — this network appears to block SMTP. Try another network."
      return "Mail server error. Check network and Settings, then retry."
    }
    if (line.startsWith("ERROR too-large"))
      return Model.errorMessage("too-large")
    if (line.startsWith("ERROR unsupported-type"))
      return Model.errorMessage("unsupported-type")
    if (line.startsWith("ERROR no-such-file"))
      return "File not found. Choose it again."
    if (line.startsWith("ERROR bad-to"))
      return Model.errorMessage("bad-to")
    if (line.startsWith("ERROR bad-args"))
      return "Invalid settings. Remove line breaks from the email fields, then retry."
    if (line.startsWith("ERROR unreadable"))
      return "Could not read the file. Check its permissions, then retry."
    if (line.startsWith("ERROR internal"))
      return "Send failed unexpectedly. Check Settings, then retry."
    if (line !== "") return line
    return "Send failed with no message."
  }

  // System file picker (`omarchy file select`, the XDG Desktop Portal
  // chooser), run out-of-process: exit 0 prints the absolute path on stdout,
  // 1 means the user cancelled, 2 means the chooser itself failed. The secret
  // never passes through here; stdout is a path only.
  Process {
    id: chooseProc
    command: ["omarchy", "file", "select",
      "--title", "Choose an EPUB or PDF",
      "--extensions", "epub pdf"]
    stdout: StdioCollector {
      id: chooseStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var picked = String(chooseStdout.text).trim()
      if (exitCode === 0 && picked !== "") {
        root.pickFile(picked)
      } else if (exitCode !== 1) {
        root.sendState = Model.STATUS_ERROR
        root.statusText = "Could not open the system file chooser. Check that xdg-desktop-portal is running."
      }
      root.open()
    }
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
        root.statusText = "File not found. Choose it again."
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

  // Boolean presence check only: consumes the OK/MISSING line, never a secret.
  Process {
    id: secretProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var line = String(text).trim()
        if (line === "OK") root.secretState = "saved"
        else root.secretState = (root.smtpUser === "" || root.smtpHost === "") ? "unconfigured" : "missing"
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.secretState === "checking")
        root.secretState = (root.smtpUser === "" || root.smtpHost === "") ? "unconfigured" : "missing"
    }
  }

  // Stores the pasted secret: it is written once to the helper's stdin and the
  // field is cleared in the same breath, so it is not kept in QML.
  Process {
    id: storeSecretProc
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var line = String(text).trim()
        if (line === "OK stored") {
          root.secretNote = ""
          root.verifySecret()
        } else {
          root.secretNote = line.startsWith("ERROR empty-secret")
            ? "Enter the app-password first."
            : "Could not save to the keyring."
        }
      }
    }
    onStarted: {
      write(secretField.text.trim() + "\n")
      secretField.text = ""
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.secretNote === "")
        root.secretNote = "Could not save to the keyring."
    }
  }

  // Debounced settings persistence while typing in Settings.
  Timer {
    id: settingsCommit
    interval: 400
    repeat: false
    onTriggered: root.commitFields()
  }

  // Re-check the keyring once the key inputs settle.
  Timer {
    id: secretRecheck
    interval: 600
    repeat: false
    onTriggered: root.verifySecret()
  }

  // Safety net: a wedged SMTP handshake must not pin the panel on "Sending…".
  // 50 MB over a slow uplink can take minutes, so this only catches a stall,
  // it is not a transfer deadline.
  Timer {
    id: sendTimeout
    interval: 300000
    repeat: false
    onTriggered: {
      if (!root.sending) return
      root.sendTimedOut = true
      sendProc.running = false
      root.sendState = Model.STATUS_ERROR
      root.statusText = "Timed out waiting for the mail server. Check network and retry."
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.showSettings && (
        toField.activeFocus || fromField.activeFocus || hostField.activeFocus
        || portField.activeFocus || userField.activeFocus || secretField.activeFocus)
      onCloseRequested: {
        if (root.showSettings) root.closeSettings()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: {
        if (!root.showSettings && root.sendState !== Model.STATUS_SENDING) root.send()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        Column {
          id: column
          width: parent.width
          spacing: Style.space(12)

          // ================= MAIN VIEW =================
          Item {
            id: mainView
            visible: !root.showSettings
            width: parent.width
            implicitHeight: mainColumn.implicitHeight

            Column {
              id: mainColumn
              width: parent.width
              spacing: Style.space(12)

              Item {
                id: mainHeader
                width: parent.width
                implicitHeight: mainHero.implicitHeight

                PanelHero {
                  id: mainHero
                  width: parent.width
                  title: "Send to Kindle"
                  meta: "EPUB · PDF · UP TO 50 MB"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily

                  trailingControl: Component {
                    PanelActionButton {
                      iconText: "\uDB81\uDC93"
                      tooltipText: "Settings"
                      foreground: mainHero.foreground
                      fontFamily: mainHero.fontFamily
                      onClicked: root.openSettings()
                    }
                  }
                }
              }

              // File card: empty drop-zone, or name + type/size + clear.
              BorderSurface {
                width: parent.width
                color: Style.normalFillFor(root.contentForeground, Color.accent)
                borderSpec: Border.controlSpec("normal", root.contentForeground, Color.accent)
                radius: Style.cornerRadius

                Column {
                  id: cardColumn
                  anchors.left: parent.left
                  anchors.right: clearButton.left
                  anchors.leftMargin: parent.borderLeft + Style.spacing.controlPaddingX
                  anchors.rightMargin: Style.spacing.controlGap
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  // Empty state.
                  Text {
                    visible: root.filePath === ""
                    textFormat: Text.PlainText
                    text: "\uDB80\uDE19"
                    color: root.dimmed
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.display
                    anchors.horizontalCenter: parent.horizontalCenter
                  }
                  Text {
                    visible: root.filePath === ""
                    textFormat: Text.PlainText
                    text: "Choose an EPUB or PDF"
                    color: root.dimmed
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    anchors.horizontalCenter: parent.horizontalCenter
                  }
                  Button {
                    visible: root.filePath === ""
                    text: "Choose file"
                    anchors.horizontalCenter: parent.horizontalCenter
                    enabled: !root.sending && !chooseProc.running
                    onClicked: {
                      if (chooseProc.running) return
                      // The chooser is a normal toplevel below the panel's
                      // layer-shell overlay, so leave the panel before
                      // launching it (same as the shell before external GUI).
                      root.close()
                      chooseProc.running = true
                    }
                  }

                  // Selected file.
                  Text {
                    visible: root.filePath !== ""
                    textFormat: Text.PlainText
                    width: parent.width
                    text: root.fileName
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideMiddle
                  }
                  Text {
                    visible: root.filePath !== ""
                    textFormat: Text.PlainText
                    width: parent.width
                    text: root.fileFormat + " · " + root.fileSizeText
                    color: root.dimmed
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }

                PanelActionButton {
                  id: clearButton
                  visible: root.filePath !== ""
                  anchors.right: parent.right
                  anchors.rightMargin: parent.borderRight + Style.spacing.controlGap
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "\uDB80\uDD56"
                  tooltipText: "Clear"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  enabled: !root.sending
                  onClicked: root.clearFile()
                }

                implicitHeight: cardColumn.implicitHeight + Style.spacing.controlPaddingY * 2
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.toEmail !== "" ? "To " + root.toEmail : "To not set — open Settings"
                color: root.dimmed
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
              }

              Button {
                width: parent.width
                focusable: true
                enabled: !root.sending && root.filePath !== "" && root.configured
                text: root.sendButtonText()
                onClicked: root.send()
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.statusText
                color: root.sendState === Model.STATUS_ERROR ? Color.urgent : root.dimmed
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: root.sendState === Model.STATUS_SENT
                wrapMode: Text.WordWrap
              }
            }
          }

          // ================= SETTINGS VIEW =================
          Item {
            id: settingsView
            visible: root.showSettings
            width: parent.width
            implicitHeight: settingsColumn.implicitHeight

            Column {
              id: settingsColumn
              width: parent.width
              spacing: Style.space(12)

              Row {
                width: parent.width
                spacing: Style.spacing.controlGap

                PanelActionButton {
                  iconText: "\uDB80\uDD4C"
                  tooltipText: "Back"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  anchors.verticalCenter: parent.verticalCenter
                  onClicked: root.closeSettings()
                }

                Text {
                  textFormat: Text.PlainText
                  text: "Settings"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              PanelSectionHeader {
                width: parent.width
                text: "DESTINATION"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
              }

              TextField {
                id: toField
                width: parent.width
                placeholderText: "you@kindle.com"
                font.family: root.contentFontFamily
                foreground: root.contentForeground
                onTextChanged: root.onSettingsFieldEdited()
                Keys.onEscapePressed: root.closeSettings()
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "Must end in @kindle.com or @free.kindle.com."
                color: root.dimmed
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              PanelSeparator { width: parent.width; foreground: root.contentForeground }

              PanelSectionHeader {
                width: parent.width
                text: "SECRET (KEYRING)"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.secretState === "saved" ? "Saved in keyring"
                  : root.secretState === "missing" ? "Not saved"
                  : root.secretState === "checking" ? "Checking…"
                  : root.secretState === "unconfigured" ? "Not configured yet"
                  : "Not checked"
                color: root.secretState === "missing" ? Color.urgent
                  : root.secretState === "saved" ? root.contentForeground
                  : root.dimmed
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                visible: root.effectiveSmtpUser() === "" || root.effectiveSmtpHost() === ""
                textFormat: Text.PlainText
                width: parent.width
                text: "Set SMTP user and host in Advanced first — the key is user@host."
                color: Color.urgent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Row {
                width: parent.width
                spacing: Style.spacing.controlGap

                TextField {
                  id: secretField
                  width: parent.width - saveSecretButton.width - parent.spacing
                  password: true
                  placeholderText: "App-password"
                  font.family: root.contentFontFamily
                  foreground: root.contentForeground
                  enabled: !storeSecretProc.running
                  Keys.onEscapePressed: root.closeSettings()
                  onAccepted: root.storeSecret()
                }
                Button {
                  id: saveSecretButton
                  text: storeSecretProc.running ? "Saving…" : "Save"
                  focusable: true
                  enabled: !storeSecretProc.running && root.effectiveSmtpUser() !== ""
                    && root.effectiveSmtpHost() !== "" && secretField.text !== ""
                  onClicked: root.storeSecret()
                }
              }
              Text {
                visible: root.secretNote !== ""
                textFormat: Text.PlainText
                width: parent.width
                text: root.secretNote
                color: Color.urgent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Button {
                width: parent.width
                text: "Verify"
                focusable: true
                enabled: root.secretState !== "checking"
                onClicked: root.verifySecret()
              }

              PanelSeparator { width: parent.width; foreground: root.contentForeground }

              PanelSectionHeader {
                width: parent.width
                text: "FORMAT"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
              }

              Toggle {
                width: parent.width
                label: "Convert to Kindle format"
                description: "Sends with subject “convert” so Amazon converts EPUB."
                checked: root.convert
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.persistSettings({ convert: !checked })
              }

              PanelSeparator { width: parent.width; foreground: root.contentForeground }

              Button {
                width: parent.width
                text: (root.showAdvanced ? "Hide advanced" : "Show advanced")
                focusable: true
                onClicked: root.showAdvanced = !root.showAdvanced
              }

              Column {
                visible: root.showAdvanced
                width: parent.width
                spacing: Style.space(12)

                PanelSectionHeader {
                  width: parent.width
                  text: "SENDER & SMTP"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                }

                TextField {
                  id: fromField
                  width: parent.width
                  placeholderText: "Approved sender email"
                  font.family: root.contentFontFamily
                  foreground: root.contentForeground
                  onTextChanged: root.onSettingsFieldEdited()
                  Keys.onEscapePressed: root.closeSettings()
                }
                Row {
                  width: parent.width
                  spacing: Style.spacing.controlGap

                  TextField {
                    id: hostField
                    width: parent.width - portField.width - parent.spacing
                    placeholderText: "smtp.gmail.com"
                    font.family: root.contentFontFamily
                    foreground: root.contentForeground
                    onTextChanged: root.onKeyFieldEdited()
                    Keys.onEscapePressed: root.closeSettings()
                  }
                  TextField {
                    id: portField
                    width: Style.space(80)
                    placeholderText: "587"
                    inputMethodHints: Qt.ImhDigitsOnly
                    font.family: root.contentFontFamily
                    foreground: root.contentForeground
                    onTextChanged: root.onSettingsFieldEdited()
                    Keys.onEscapePressed: root.closeSettings()
                  }
                }
                TextField {
                  id: userField
                  width: parent.width
                  placeholderText: "SMTP username"
                  font.family: root.contentFontFamily
                  foreground: root.contentForeground
                  onTextChanged: root.onKeyFieldEdited()
                  Keys.onEscapePressed: root.closeSettings()
                }
              }

              Button {
                width: parent.width
                focusable: true
                text: "Done"
                onClicked: root.closeSettings()
              }
            }
          }
        }
      }
    }
  }
}
