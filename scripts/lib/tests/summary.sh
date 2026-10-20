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

    ok "Nextcloud-Gr tests completed."

    echo

    info "Review the output above for warnings or failures."

    echo

    ok "Test summary completed."
}