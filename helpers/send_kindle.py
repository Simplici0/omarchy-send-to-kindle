#!/usr/bin/env python3
"""Send an EPUB/PDF to a @kindle.com address via the user's SMTP provider.

Reads the SMTP secret itself via `secret-tool lookup` (Secret Service /
gnome-keyring). The secret NEVER travels on argv or through QML.

Usage (invoked by Panel.qml, not by hand):
    send_kindle.py --smtp-host H --smtp-port P --smtp-user U \
        --from A --to B --file PATH [--subject S]
    send_kindle.py --check-secret --smtp-user U --smtp-host H
    send_kindle.py --store-secret --smtp-user U --smtp-host H   # secret on stdin

Prints `OK <detail>` or `ERROR <code> [detail]` on stdout; exit 0/1/2.
Exit 2 = bad arguments, 1 = validation/send/auth failure, 0 = success.
"""
import argparse
import mimetypes
import os
import smtplib
import ssl
import subprocess
import sys
from email.message import EmailMessage
from pathlib import Path

MAX_BYTES = 50 * 1024 * 1024
SUPPORTED_SUFFIXES = {".epub", ".pdf"}


def fail(code, detail=""):
    line = "ERROR " + code + (" " + detail if detail else "")
    print(line, flush=True)
    return 1


def lookup_secret(user, host):
    """Read the SMTP password from the login keyring. None when missing."""
    key = user + "@" + host
    try:
        proc = subprocess.run(
            ["secret-tool", "lookup", "smtp", key],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    secret = (proc.stdout or "").rstrip("\n")
    return secret if secret else None


def build_args(argv):
    parser = argparse.ArgumentParser(description="Send EPUB/PDF to Kindle via SMTP")
    parser.add_argument("--smtp-host", required=False, default="")
    parser.add_argument("--smtp-port", required=False, default=587, type=int)
    parser.add_argument("--smtp-user", required=False, default="")
    parser.add_argument("--from", dest="from_addr", required=False, default="")
    parser.add_argument("--to", required=False, default="")
    parser.add_argument("--file", dest="file_path", required=False, default="")
    parser.add_argument("--subject", default="convert")
    parser.add_argument("--check-secret", action="store_true",
                        help="Only verify the keyring secret exists (prints OK or MISSING, never the secret)")
    parser.add_argument("--store-secret", action="store_true",
                        help="Read the secret from stdin and store it in the keyring (never printed, never in argv)")
    return parser.parse_args(argv)


def main(argv=None):
    try:
        args = build_args(argv if argv is not None else sys.argv[1:])
    except SystemExit as exc:
        # argparse already printed usage to stderr; mirror a machine line.
        print("ERROR bad-args", flush=True)
        return 2
    if args.check_secret:
        if not args.smtp_user or not args.smtp_host:
            print("ERROR bad-args", flush=True)
            return 2
        print("OK" if lookup_secret(args.smtp_user, args.smtp_host) is not None else "MISSING", flush=True)
        return 0

    if args.store_secret:
        if not args.smtp_user or not args.smtp_host:
            print("ERROR bad-args", flush=True)
            return 2
        # The secret arrives on stdin (piped by the panel), never on argv, and
        # is forwarded to secret-tool's stdin without ever being printed.
        secret = (sys.stdin.readline() or "").rstrip("\n")
        if secret == "":
            print("ERROR empty-secret", flush=True)
            return 1
        key = args.smtp_user + "@" + args.smtp_host
        try:
            proc = subprocess.run(
                ["secret-tool", "store", "--label", "Omarchy Send to Kindle", "smtp", key],
                input=secret + "\n",
                text=True,
                capture_output=True,
                timeout=15,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            print("ERROR store-failed", flush=True)
            return 1
        if proc.returncode != 0:
            print("ERROR store-failed", flush=True)
            return 1
        print("OK stored", flush=True)
        return 0

    for required in ("smtp_host", "smtp_user", "from_addr", "to", "file_path"):
        if not getattr(args, required):
            print("ERROR bad-args", flush=True)
            return 2

    addr = args.to.strip().lower()
    if not (addr.endswith("@kindle.com") or addr.endswith("@free.kindle.com")):
        return fail("bad-to", "destination must end in @kindle.com")

    path = Path(os.path.expandvars(os.path.expanduser(args.file_path)))
    if path.suffix.lower() not in SUPPORTED_SUFFIXES:
        return fail("unsupported-type", "only EPUB and PDF are accepted")
    if not path.is_file():
        return fail("no-such-file", str(path))
    try:
        size = path.stat().st_size
    except OSError as exc:
        return fail("unreadable", str(exc))
    if size > MAX_BYTES:
        return fail("too-large", "limit is 50 MB, file is %d bytes" % size)

    secret = lookup_secret(args.smtp_user, args.smtp_host)
    if secret is None:
        return fail("auth-missing",
                    "run: secret-tool store --label 'Omarchy Send to Kindle' smtp "
                    + args.smtp_user + "@" + args.smtp_host)

    # Keep MIME mapping explicit: epub is not in every mimetypes table.
    if path.suffix.lower() == ".epub":
        maintype, subtype = "application", "epub+zip"
    else:
        guessed = mimetypes.guess_type(str(path))[0] or "application/pdf"
        maintype, subtype = guessed.split("/", 1)

    try:
        data = path.read_bytes()
    except OSError as exc:
        return fail("unreadable", str(exc))

    try:
        msg = EmailMessage()
        msg["From"] = args.from_addr
        msg["To"] = args.to
        msg["Subject"] = args.subject
        msg.set_content("Sent from the Omarchy Send to Kindle plugin.")
        msg.add_attachment(data, maintype=maintype, subtype=subtype, filename=path.name)
    except ValueError:
        # A line break in a user-set header or in the file name cannot be
        # encoded as a mail header; report it instead of crashing.
        return fail("bad-args", "invalid header or file name")

    # Verify the server certificate: smtplib's implicit context is
    # _create_unverified_context (CERT_NONE, no hostname check), which would
    # let an on-path attacker terminate TLS and capture the app-password.
    context = ssl.create_default_context()
    try:
        if args.smtp_port == 465:
            with smtplib.SMTP_SSL(args.smtp_host, args.smtp_port, timeout=30, context=context) as smtp:
                smtp.login(args.smtp_user, secret)
                smtp.send_message(msg)
        else:
            with smtplib.SMTP(args.smtp_host, args.smtp_port, timeout=30) as smtp:
                smtp.starttls(context=context)
                smtp.login(args.smtp_user, secret)
                smtp.send_message(msg)
    except UnicodeEncodeError:
        # smtplib encodes AUTH credentials as ASCII; report the fix without
        # echoing the user or the secret.
        return fail("smtp-auth", "credentials must be ASCII; use an app password")
    except smtplib.SMTPAuthenticationError as exc:
        return fail("smtp-auth", str(exc).splitlines()[0] if str(exc) else "")
    except (smtplib.SMTPException, OSError) as exc:
        first = str(exc).splitlines()[0] if str(exc) else exc.__class__.__name__
        return fail("smtp-error", first)

    print("OK sent " + path.name, flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        # Terminal safety net: Panel.qml only parses `OK` / `ERROR <code>`
        # lines, so an unexpected exception must still honor that contract.
        # Only the exception class name is printed, never values or messages.
        print("ERROR internal " + exc.__class__.__name__, flush=True)
        sys.exit(1)
