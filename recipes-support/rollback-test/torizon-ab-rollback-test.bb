SUMMARY = "TEST-ONLY: a greenboot health check that always fails (rollback test)"
DESCRIPTION = "Installs a required greenboot check that always fails, so an \
image built with this package is treated as an unhealthy update and triggers \
the A/B rollback. Bake it into a throwaway .swu to validate rollback, then \
rebuild without it. DO NOT ship in production images."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

SRC_URI = "file://99-force-fail.sh"

RDEPENDS:${PN} = "greenboot"

do_install() {
    install -d ${D}${sysconfdir}/greenboot/check/required.d
    install -m 0755 ${WORKDIR}/99-force-fail.sh ${D}${sysconfdir}/greenboot/check/required.d/99-force-fail.sh
}

FILES:${PN} = "${sysconfdir}/greenboot/check/required.d/99-force-fail.sh"
