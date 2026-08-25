# RAUC A/B slot-selection preamble (prepended to the shared boot body).
#
# Reads RAUC's uboot-backend variables (BOOT_ORDER + BOOT_<slot>_LEFT), picks the
# first slot with attempts left, decrements its trial counter (power-safe:
# saveenv before boot), and rolls back when a slot's attempts run out. greenboot's
# `rauc status mark-good` resets the counter on a healthy boot.
#
# Sets for the shared body: ${rootlabel} (GPT partlabel of the chosen slot) and
# ${bootargs} (root=PARTLABEL=… rauc.slot=…).

test -n "${BOOT_ORDER}"  || setenv BOOT_ORDER "A B"
test -n "${BOOT_A_LEFT}" || setenv BOOT_A_LEFT 3
test -n "${BOOT_B_LEFT}" || setenv BOOT_B_LEFT 0

setenv raucslot
for slot in ${BOOT_ORDER}; do
  if test -z "${raucslot}"; then
    if test "${slot}" = "A"; then
      if test "${BOOT_A_LEFT}" -gt 0; then
        setexpr BOOT_A_LEFT ${BOOT_A_LEFT} - 1
        setenv raucslot A; setenv rootlabel rootfs_a
      fi
    fi
    if test "${slot}" = "B"; then
      if test "${BOOT_B_LEFT}" -gt 0; then
        setexpr BOOT_B_LEFT ${BOOT_B_LEFT} - 1
        setenv raucslot B; setenv rootlabel rootfs_b
      fi
    fi
  fi
done

if test -z "${raucslot}"; then
  echo "RAUC: no bootable slot left (BOOT_ORDER=${BOOT_ORDER}); halting."
  exit
fi

saveenv

setenv bootargs "root=PARTLABEL=${rootlabel} rootfstype=ext4 rw rauc.slot=${raucslot} ${tdxargs}"
