# Security Policy

## Supported versions

Only the latest release receives security fixes.

| Version | Supported |
| ------- | --------- |
| 0.1.x   | Yes       |

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report them privately through GitHub: go to the repository's **Security** tab and
choose **Report a vulnerability**. If that option is not available, open a
regular issue that says only that you have a security report, without any details,
and the maintainer will arrange a private channel.

Include, where you can:

- the version or commit you tested
- the stage and command involved
- the steps to reproduce, and what you expected to happen
- the impact you believe it has

You should receive an acknowledgement within a reasonable time. Please allow time for a
fix before any public disclosure.

## Scope

In scope:

- disk selection or erasure that affects a disk other than the one the user chose
- password or secret exposure (on the command line, in logs, on disk, or to third parties)
- privilege escalation or unsafe file handling in the installer
- bypasses of the boot-medium, mount, or holder checks

Out of scope:

- data loss from selecting the wrong disk after reading the prompts
- weaknesses in Arch Linux, systemd-boot, cryptsetup, or other upstream software,
  which should be reported to those projects
