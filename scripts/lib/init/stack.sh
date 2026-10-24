#!/usr/bin/env bash

init_stack()
{
    print_section "Project stack"

    assert_sync_paths

    log_info "Preparing Nextcloud-Gr stack..."

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

    log_success "Nextcloud-Gr stack prepared."
}
