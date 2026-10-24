#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/tests/summary.sh
#
# Description:
#   Print Nextcloud-Gr test summary.
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