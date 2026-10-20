#!/usr/bin/env bash
###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/tests/docker.sh
#
# Description:
#   Docker validation tests.
#
###############################################################################

test_docker()
{
    print_section "Docker"

    docker info >/dev/null 2>&1 \
        || fail "Docker daemon is not available."

    ok "Docker daemon OK."
}
