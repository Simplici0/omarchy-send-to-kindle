#!/usr/bin/env python3
"""Send an EPUB/PDF to a @kindle.com address via the user's SMTP provider.

Reads the SMTP secret itself via `secret-tool lookup` (Secret Service /
gnome-keyring). The secret NEVER travels on argv or through QML.

Usage (invoked by Panel.qml, not by hand):
    send_kindle.py --smtp-host H --smtp-port P --smtp-user U \
        --from A --to B --file PATH [--no-tls] [--subject S]

Prints `OK <detail>` or `ERROR <code> [detail]` on stdout; exit 0/1/2.
Exit 2 = usage/validation error, 1 = send/auth failure, 0 = success.
"""
import argparse
import mimetypes
import os
import smtplib
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
    parser.add_argument("--smtp-host", required=True)
    parser.add_argument("--smtp-port", required=True, type=int)
    parser.add_argument("--smtp-user", required=True)
    parser.add_argument("--from", dest="from_addr", required=True)
    parser.add_argument("--to", required=True)
    parser.add_argument("--file", dest="file_path", required=True)
    parser.add_argument("--no-tls", action="store_true",
                        help="Skip STARTTLS (local relay without TLS only)")
    parser.add_argument("--subject", default="convert")
    return parser.parse_args(argv)


def main(argv=None):
    try:
        args = build_args(argv if argv is not None else sys.argv[1:])
    except SystemExit as exc:
        # argparse already printed usage to stderr; mirror a machine line.
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

    msg = EmailMessage()
    msg["From"] = args.from_addr
    msg["To"] = args.to
    msg["Subject"] = args.subject
    msg.set_content("Sent from the Omarchy Send to Kindle plugin.")
    msg.add_attachment(data, maintype=maintype, subtype=subtype, filename=path.name)

    try:
        if args.smtp_port == 465:
            with smtplib.SMTP_SSL(args.smtp_host, args.smtp_port, timeout=30) as smtp:
                smtp.login(args.smtp_user, secret)
                smtp.send_message(msg)
        else:
            with smtplib.SMTP(args.smtp_host, args.smtp_port, timeout=30) as smtp:
                if not args.no_tls:
                    smtp.starttls()
                smtp.login(args.smtp_user, secret)
                smtp.send_message(msg)
    except smtplib.SMTPAuthenticationError as exc:
        return fail("smtp-auth", str(exc).splitlines()[0] if str(exc) else "")
    except (smtplib.SMTPException, OSError) as exc:
        first = str(exc).splitlines()[0] if str(exc) else exc.__class__.__name__
        return fail("smtp-error", first)

    print("OK sent " + path.name, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
