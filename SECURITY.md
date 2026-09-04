# Security

This is a filesystem driver. Two kinds of finding matter more here than in
most projects, and both deserve a private report before a public issue:

- **Data loss or corruption** — anything that makes a volume this driver
  wrote unreadable, or writes the wrong bytes, on any medium.
- **Memory safety on hostile input** — a crafted disk image that crashes,
  hangs, or reads or writes out of bounds in the extension. The extension is
  sandboxed, but it runs on every disk that is plugged in, before the user
  has agreed to anything.

## Reporting

Use GitHub's private vulnerability reporting for this repository:
**Security → Report a vulnerability**. Nothing you write there is public
until a fix is out and you agree to disclosure.

Please include:

- `Ext4Mac version` (the build id) and your macOS version
- `Ext4Mac last-error /dev/diskN` for the volume involved, if there is one
- the extension's log lines: `log show --last 10m --predicate 'subsystem ==
  "dev.h3ct0r.ext4"'`
- for a hostile-image finding, the image or a `gzip` of it, and the command
  that triggers it (`build/bin/ext4dump <img> <verb>` reproduces most of them
  offline)

You can expect an acknowledgement within a few days, and a fix landed as a
hostile fixture proven red before green — the same way the fuzzer's findings
land — with credit unless you prefer none.

## Scope

In scope: `Core/`, `Extension/`, `Shared/`, `App/`, the build and release
scripts, and the vendored lwext4 as patched here.

Out of scope: the upstream lwext4 tree as shipped by its author (report those
there as well), macOS and FSKit themselves, and the limits already documented
in `docs/ENVELOPE.md` — in particular the write barrier FSKit does not offer,
which is a platform limit, not a vulnerability.
