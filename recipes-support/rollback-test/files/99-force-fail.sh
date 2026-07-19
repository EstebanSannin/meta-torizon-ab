#!/bin/sh
# TEST-ONLY greenboot required check that always fails, to exercise the A/B
# rollback path. An image containing this will fail its health check on every
# boot, so after 'bootlimit' attempts GRUB rolls back to the other slot.
echo "torizon-ab-rollback-test: forcing greenboot failure to test rollback" >&2
exit 1
