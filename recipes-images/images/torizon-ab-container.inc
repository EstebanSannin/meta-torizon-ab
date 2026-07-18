# Container-engine packages for the A/B (no-OSTree) Torizon variant.
# Mirrors meta-toradex-torizon's torizon-container.inc (kept as a local copy so
# it resolves from this layer's recipe dir via 'require').
#
# Note: container storage lives under /var/lib/docker, i.e. on the shared 'data'
# partition, so containers/images persist across A/B rootfs updates.

CORE_IMAGE_BASE_INSTALL:append = " \
    ${VIRTUAL-RUNTIME_container_engine} \
    docker-compose \
    docker-compose-up \
    docker-integrity-checker \
    docker-watchdog \
    docker-auto-prune \
"
