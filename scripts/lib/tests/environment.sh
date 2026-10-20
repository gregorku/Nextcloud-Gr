#!/usr/bin/env bash
###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/tests/environment.sh
#
# Description:
#   Environment validation tests.
#
###############################################################################

test_environment()
{
    print_section ".env"

    require_file "${STACK_DIR}/.env"

    env_validate

    ok ".env OK."
}