#!/usr/bin/env bash
# sb-reboot — the agent fleet's ONE privileged reboot path (SCRUM-1926).
#
# Installed to /usr/local/bin/sb-reboot by base/19g and run as root through a
# NARROW NOPASSWD sudoers rule scoped to ONLY this wrapper (`sudo -n sb-reboot`),
# by the SideButton daemon's POST /api/system/reboot handler. Same trust-boundary
# pattern as sb-self-update (base/08): the wrapper IS the boundary, because sudoers
# cannot constrain arguments.
#
# WHY A WRAPPER AND NOT `sudo reboot`: the agent user is in no sudo group and its
# sudoers granted exactly two other wrappers, so `sudo reboot` was denied on every
# box in the fleet ("agent : command not allowed ; COMMAND=/usr/sbin/reboot") while
# the daemon still answered {"ok":true}. Granting /usr/sbin/reboot directly would
# have worked, but a wrapper keeps the grant auditable (it logs who asked) and lets
# us pick the mechanism below.
#
# WHY `systemctl reboot` AND NOT `reboot`: this image ships lightdm + unity-greeter
# as an unpinned Recommends of xfce4 (base/04), running an invisible Xorg on seat0
# while the real desktop is Xvfb :10 + xrdp. The greeter holds a `handle-power-key`
# BLOCK inhibitor from boot, so an ACPI power press is deferred to it and swallowed.
# `systemctl reboot` enqueues reboot.target with systemd directly and never consults
# that inhibitor — it is the exact mechanism that recovered agent-hz8mh-euler when
# both portal lanes could not.
#
# WHY `--no-block`: it enqueues the job and returns immediately, so this wrapper's
# EXIT CODE reports whether the reboot was actually accepted (letting the caller
# answer truthfully instead of guessing) while still leaving the daemon a moment to
# flush its HTTP response before the box goes down.
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REQUESTER="${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"
note() { logger -t sb-reboot "$1" 2>/dev/null || true; echo "sb-reboot: $1"; }

note "reboot requested by ${REQUESTER}"

if systemctl reboot --no-block; then
  note "reboot enqueued (systemctl reboot --no-block)"
  exit 0
fi

# Escalation: --force bypasses logind entirely and asks PID 1 to shut down without
# waiting on inhibitors or job ordering. Still a clean unmount (that would need a
# second --force, which we deliberately do not do). Reached only when the normal
# path was refused, e.g. a `shutdown` block inhibitor held by a stuck unit.
note "WARN systemctl reboot was refused — escalating to --force"
if systemctl --force reboot; then
  note "reboot enqueued (systemctl --force reboot)"
  exit 0
fi

note "ERROR both systemctl reboot and systemctl --force reboot failed"
exit 1
