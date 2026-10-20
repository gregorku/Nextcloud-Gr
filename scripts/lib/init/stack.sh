#!/usr/bin/env bash
#
# File: scripts/lib/init/stack.sh
#
# Description:
#   Initial preparation of the Authentik-netcup deployment stack.
#
# Responsibilities:
#   - create STACK_DIR
#   - copy all deployment items from the Git repository
#   - replace any previous content of those items
#
# This function is intended to be called ONLY from init.sh.
# For regular deployments use deploy_sync_stack().
#
# The copy removes and replaces each DEPLOY_ITEMS path and nothing
# else. Runtime .env is not a deployment item.

init_stack()
{
    print_section "Project stack"

    assert_sync_paths

    log_info "Preparing Authentik-netcup stack..."

    mkdir -p "${STACK_DIR}"

    local item
    local src
    local dst

    for item in "${DEPLOY_ITEMS[@]}"; do

        [[ "${item}" != /* && "${item}" != *..* && "${item}" != */* ]] \
            || fail "DEPLOY_ITEMS entry is not a single path name: ${item}"

        src="${GIT_DIR}/${item}"
        dst="${STACK_DIR}/${item}"

        sync_replace_item "${src}" "${dst}" "${STACK_DIR}"

        log_info "Copied ${item}"

    done

    log_success "Authentik-netcup stack prepared."
}
