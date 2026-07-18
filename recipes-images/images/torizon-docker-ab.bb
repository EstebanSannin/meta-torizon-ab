SUMMARY = "Torizon OS (A/B + SWUpdate, no OSTree) with Docker"
DESCRIPTION = "Torizon OS with the Docker container engine, without OSTree. \
Uses the classic A/B dual-partition scheme updated by SWUpdate and keeps the \
Torizon update client (aktualizr as download+verify-only primary), RAC, \
tzn-mqtt and auto-provisioning."

require torizon-ab-base.inc
require torizon-ab-container.inc

VIRTUAL-RUNTIME_container_engine = "docker"
IMAGE_VARIANT = "Docker-AB"

inherit extrausers

EXTRA_USERS_PARAMS += "\
usermod -a -G docker torizon; \
"

# REVIEW: the Docker rootfs is significantly larger than minimal. The A/B slot
# size in wic/torizon-ab-x86.wks (default 2 GiB/slot) may be too small — bump
# the two 'otaroot_*' --fixed-size values (e.g. to 4096) if do_image_wic fails
# with a "does not fit" error.
