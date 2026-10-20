#!/usr/bin/env bash
deploy_wait_dockge() {
    print_section "Waiting for Dockge"
    for i in $(seq 1 30); do
        if docker_container_running "${DOCKGE_CONTAINER}"; then
            log_success "Dockge is running."
            return
        fi
        sleep 1
    done
    fail "Timed out waiting for Dockge."
}
