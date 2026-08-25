SUMMARY = "DEV-ONLY: dev SSH key + passwordless sudo for freshly-flashed A/B images"
DESCRIPTION = "Makes a freshly-flashed Torizon OS A/B DEVELOPMENT image usable \
over SSH immediately, with no manual first-boot setup: installs a development SSH \
public key for the 'torizon' user and enables passwordless sudo, via a one-shot \
first-boot service. This is the access counterpart of the in-tree dev signing \
keys -- NOT for production. Remove it (or replace the key) for real deployments."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = " \
    file://dev-authorized_keys \
    file://torizon-ab-devaccess.sh \
    file://torizon-ab-devaccess.service \
"

SYSTEMD_SERVICE:${PN} = "torizon-ab-devaccess.service"

do_install() {
    install -d ${D}${datadir}/torizon-ab-devaccess
    install -m 0644 ${WORKDIR}/dev-authorized_keys ${D}${datadir}/torizon-ab-devaccess/dev-authorized_keys

    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/torizon-ab-devaccess.sh ${D}${bindir}/torizon-ab-devaccess.sh

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${WORKDIR}/torizon-ab-devaccess.service ${D}${systemd_unitdir}/system/torizon-ab-devaccess.service
}

FILES:${PN} = " \
    ${datadir}/torizon-ab-devaccess/dev-authorized_keys \
    ${bindir}/torizon-ab-devaccess.sh \
    ${systemd_unitdir}/system/torizon-ab-devaccess.service \
"
