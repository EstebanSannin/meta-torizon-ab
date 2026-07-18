SUMMARY = "Torizon OS Reference Minimal Image (A/B + SWUpdate, no OSTree)"
DESCRIPTION = "Torizon OS without a container engine and without OSTree. \
Uses a classic A/B dual-partition scheme updated by SWUpdate, while keeping \
the Torizon update client (aktualizr, configured as a download+verify-only \
primary), Remote Access Client, tzn-mqtt and auto-provisioning."

require torizon-ab-base.inc

IMAGE_VARIANT = "Minimal-AB"
