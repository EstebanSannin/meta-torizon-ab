#!/bin/sh
# DEV-ONLY: make a freshly-flashed A/B dev image immediately usable over SSH with
# no manual first-boot setup. Installs a development SSH public key for the
# 'torizon' user and enables passwordless sudo. Idempotent; runs once at first
# boot (after /home is mounted/seeded). NOT for production images -- this is the
# access counterpart of the in-tree dev signing keys.
set -eu

U=torizon
H="/home/${U}"

# Wait for the user's home to exist (seeded from the rootfs onto the data partition).
[ -d "${H}" ] || exit 0

install -d -m 0700 "${H}/.ssh"
install -m 0600 /usr/share/torizon-ab-devaccess/dev-authorized_keys "${H}/.ssh/authorized_keys"
chown -R "${U}:${U}" "${H}/.ssh"

# Passwordless sudo for the dev user (dev only).
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${U}" > /etc/sudoers.d/90-torizon-nopw
chmod 0440 /etc/sudoers.d/90-torizon-nopw

# Clear the stock forced-first-login password change / expiry (dev only). Torizon
# ships 'torizon' with an expired password so the human sets one at first login;
# that makes key-based SSH unusable headlessly -- PAM's account phase returns
# "password change required" and sshd refuses the session BEFORE the sudoers rule
# above ever applies. Reset last-change to now and disable aging so the installed
# key alone grants access with no manual first-boot step. (mkpasswd not needed --
# access is key-only; the account simply must not be in the must-change state.)
chage -d "$(date +%Y-%m-%d)" -m 0 -M -1 -I -1 -E -1 "${U}" 2>/dev/null || true
passwd -x -1 "${U}" 2>/dev/null || true
