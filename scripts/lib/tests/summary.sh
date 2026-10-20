#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/tests/summary.sh
#
# Description:
#   Print Authentik-netcup test summary.
#
###############################################################################

###############################################################################
# Test summary
###############################################################################

test_summary()
{
    print_section "Finished"

    ok "Authentik-netcup tests completed."

    echo

    info "Review the output above for warnings or failures."

    echo

    ok "Test summary completed."
}