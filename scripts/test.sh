#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/test.sh
#
# Description:
#   Run Nextcloud-Gr tests.
#
# Usage:
#   ./scripts/test.sh
#   ./scripts/test.sh --static
#   ./scripts/test.sh --help
#
#   Without arguments this expects the Incus container: root, Docker,
#   Dockge and the running stack. A check that cannot be executed fails.
#
#   --static reads the Git checkout and temporary directories. It does
#   not need root and it does not write to /docker-data. docker compose
#   config is reported as not executed when the Docker CLI is absent.
#
###############################################################################

set -Eeuo pipefail

###############################################################################
# Directories
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################################################################
# Configuration
###############################################################################

source "${SCRIPT_DIR}/config.sh"

###############################################################################
# Core libraries
###############################################################################

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/filesystem.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

###############################################################################
# Checks library
###############################################################################

source "${SCRIPT_DIR}/lib/checks/load.sh"

###############################################################################
# Environment library
###############################################################################

source "${SCRIPT_DIR}/lib/env/load.sh"

###############################################################################
# Deployment and backup libraries used by static tests
###############################################################################

source "${SCRIPT_DIR}/lib/deploy/stack.sh"
source "${SCRIPT_DIR}/lib/mount.sh"
source "${SCRIPT_DIR}/lib/upgrade/version.sh"
source "${SCRIPT_DIR}/lib/upgrade/php.sh"
source "${SCRIPT_DIR}/lib/upgrade/apps.sh"
source "${SCRIPT_DIR}/lib/upgrade/sequence.sh"
source "${SCRIPT_DIR}/lib/backup/private.sh"
source "${SCRIPT_DIR}/lib/backup/archive.sh"
source "${SCRIPT_DIR}/lib/backup/crypto.sh"
source "${SCRIPT_DIR}/lib/backup/restic.sh"
source "${SCRIPT_DIR}/lib/backup/restore-plan.sh"
source "${SCRIPT_DIR}/lib/backup/runtime.sh"
source "${SCRIPT_DIR}/lib/backup/apply.sh"

###############################################################################
# Help
###############################################################################

show_help()
{
cat <<EOF
Nextcloud-Gr

Usage:

    ./scripts/test.sh
    ./scripts/test.sh --static
    ./scripts/test.sh --help

Options:

    --static
        Validate the checkout, .env.example, Compose port bindings,
        sync path guards and backup checksums in a temporary directory.

    -h, --help
        Show this help.

Description:

    The default mode checks the deployed stack in this container:
    project files, .env, Compose, Docker, Dockge, the network and the
    published HTTP port.

EOF
}

###############################################################################
# Static mode
###############################################################################

run_static_tests()
{
    source "${SCRIPT_DIR}/lib/tests/static.sh"
    source "${SCRIPT_DIR}/lib/tests/upgrade.sh"
    source "${SCRIPT_DIR}/lib/tests/backup.sh"

    RESTORE_SKIP_USER_DATA=yes

    print_header "Nextcloud-Gr static test"

    test_repository_layout
    test_env_example
    test_runtime_placeholder_rejection
    test_compose_bindings
    test_sync_guards
    test_script_modes
    test_external_validators
    test_version_guard
    test_php_matrix
    test_custom_app_compatibility
    test_upgrade_sequence
    test_dump_kind
    test_storage_guard
    test_backup_archive
    test_backup_external_copy
    test_backup_encryption
    test_backup_plaintext_modes
    test_backup_stream_encrypt
    test_backup_destination
    test_backup_host_mount
    test_backup_cleanup_failure
    test_backup_quiesce
    test_backup_completeness
    test_restore_confirmation
    test_restore_rejects_incomplete
    test_restore_rolls_back
    test_restore_signal
    test_restore_installs_secret_key

    print_footer "Static tests completed."
}

###############################################################################
# Container mode
###############################################################################

run_runtime_tests()
{
    source "${SCRIPT_DIR}/lib/tests/project.sh"
    source "${SCRIPT_DIR}/lib/tests/stack.sh"
    source "${SCRIPT_DIR}/lib/tests/environment.sh"
    source "${SCRIPT_DIR}/lib/tests/compose.sh"
    source "${SCRIPT_DIR}/lib/tests/docker.sh"
    source "${SCRIPT_DIR}/lib/tests/dockge.sh"
    source "${SCRIPT_DIR}/lib/tests/networks.sh"
    source "${SCRIPT_DIR}/lib/tests/backend-security.sh"
    source "${SCRIPT_DIR}/lib/tests/summary.sh"

    print_header "Nextcloud-Gr test"

    check_environment
    check_docker_environment

    test_project
    test_stack
    test_environment
    test_compose
    test_docker
    test_dockge
    test_networks
    test_backend_security

    test_summary
}

###############################################################################
# Main
###############################################################################

case "${1:-}" in

    "")
        run_runtime_tests
        ;;

    --static)
        run_static_tests
        ;;

    -h|--help)
        show_help
        exit 0
        ;;

    *)
        fail "Unknown option: ${1}"
        ;;

esac
