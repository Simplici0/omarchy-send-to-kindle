// Pure validation and formatting for the Send to Kindle panel.
// Qt-free so it can be unit tested under node; QML owns all UI state.
var MAX_BYTES = 50 * 1024 * 1024 // Amazon email limit: 50 MB total per email

var STATUS_READY = "ready"
var STATUS_SENDING = "sending"
var STATUS_SENT = "sent"
var STATUS_ERROR = "error"

var SUPPORTED_EXTENSIONS = ["epub", "pdf"]

function extensionOf(path) {
  var name = String(path || "").split("/").pop()
  var dot = name.lastIndexOf(".")
  if (dot < 0) return ""
  return name.slice(dot + 1).toLowerCase()
}

function isSupportedExtension(path) {
  return SUPPORTED_EXTENSIONS.indexOf(extensionOf(path)) >= 0
}

function formatLabel(path) {
  return extensionOf(path).toUpperCase()
}

function formatBytes(n) {
  var bytes = Number(n)
  if (!isFinite(bytes) || bytes < 0) return "—"
  if (bytes < 1024) return bytes + " B"
  var units = ["KB", "MB", "GB"]
  var value = bytes / 1024
  var unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit += 1
  }
  return (value >= 100 ? Math.round(value) : value.toFixed(1)) + " " + units[unit]
}

// Local pre-flight check before launching the helper. Returns
// { ok: true } or { ok: false, error: "<reason>" }.
function validateFile(path, sizeBytes) {
  if (!path || String(path).trim() === "") return { ok: false, error: "empty-path" }
  if (!isSupportedExtension(path)) return { ok: false, error: "unsupported-type" }
  var size = Number(sizeBytes)
  if (sizeBytes !== undefined && sizeBytes !== null && sizeBytes !== "" && (!isFinite(size) || size < 0))
    return { ok: false, error: "bad-size" }
  if (isFinite(size) && size > MAX_BYTES) return { ok: false, error: "too-large" }
  return { ok: true }
}

function isKindleAddress(email) {
  var addr = String(email || "").trim().toLowerCase()
  return addr.endsWith("@kindle.com") || addr.endsWith("@free.kindle.com")
}

// Non-secret config check. The SMTP secret lives in the keyring, never here.
function validateConfig(config) {
  config = config || {}
  if (!String(config.smtpHost || "").trim()) return { ok: false, error: "missing-host" }
  var port = Number(config.smtpPort)
  if (!isFinite(port) || port <= 0 || port > 65535) return { ok: false, error: "bad-port" }
  if (!String(config.smtpUser || "").trim()) return { ok: false, error: "missing-user" }
  if (!String(config.fromEmail || "").trim()) return { ok: false, error: "missing-from" }
  if (!isKindleAddress(config.toEmail)) return { ok: false, error: "bad-to" }
  return { ok: true }
}

// Human message for a validateFile / validateConfig error code.
function errorMessage(code) {
  switch (code) {
  case "empty-path": return "Choose a file first."
  case "unsupported-type": return "Only EPUB and PDF are accepted by Send to Kindle."
  case "bad-size": return "Could not read the file size."
  case "too-large": return "Files over 50 MB are rejected by Amazon email."
  case "missing-host": return "Set the SMTP host."
  case "bad-port": return "Set a valid SMTP port (587 or 465)."
  case "missing-user": return "Set the SMTP username."
  case "missing-from": return "Set the sender email (must be Amazon-approved)."
  case "bad-to": return "Destination must end in @kindle.com."
  default: return "Unknown error."
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_BYTES: MAX_BYTES,
    STATUS_READY: STATUS_READY,
    STATUS_SENDING: STATUS_SENDING,
    STATUS_SENT: STATUS_SENT,
    STATUS_ERROR: STATUS_ERROR,
    extensionOf: extensionOf,
    isSupportedExtension: isSupportedExtension,
    formatLabel: formatLabel,
    formatBytes: formatBytes,
    validateFile: validateFile,
    isKindleAddress: isKindleAddress,
    validateConfig: validateConfig,
    errorMessage: errorMessage
  }
}
