#!/usr/bin/env bash
###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/tests/stack.sh
#
# Description:
#   Stack validation tests.
#
###############################################################################

test_stack()
{
    print_section "Stack"

    require_directory "${STACK_DIR}"
    require_file "${STACK_DIR}/compose.yml"
    require_directory "${STACK_DIR}/compose"
    require_directory "${STACK_DIR}/configs"

    ok "Stack directory OK."
}