#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/env/sync.sh
#
# Description:
#   Create or synchronize .env with .env.example.
#
# Responsibilities:
#   - Create .env on first run
#   - Preserve user values
#   - Preserve an existing generated secret
#   - Generate a secret only when the current value is missing or is
#     still a set_* placeholder
#   - Preserve comments
#   - Preserve blank lines
#   - Preserve variable order from .env.example
#   - Apply environment policy
#   - Drop variables that .env.example no longer contains
#
###############################################################################

###############################################################################
# Synchronize environment
###############################################################################

env_sync()
{
    [[ -f "${ENV_EXAMPLE_FILE}" ]] \
        || fail ".env.example not found in the runtime stack. Run ./scripts/init.sh first."

    ###########################################################################
    # First run
    ###########################################################################

    if [[ ! -f "${ENV_FILE}" ]]; then

        log_info "Environment file not found."
        log_info "Creating .env from .env.example..."

        cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
        chmod 600 "${ENV_FILE}"

        log_success "Environment file created."

    fi

    ###########################################################################
    # Load current environment
    ###########################################################################

    declare -A ENV_CURRENT
    declare -A ENV_EXAMPLE

    env_read_current ENV_CURRENT
    env_read_example ENV_EXAMPLE

    local output=""
    local line
    local key
    local example_value
    local current_value
    local value
    local policy
    local differences=0

    log_info "Synchronizing .env..."

    while IFS= read -r line || [[ -n "${line}" ]]; do

        #######################################################################
        # Preserve blank lines
        #######################################################################

        if [[ -z "${line}" ]]; then
            output+=$'\n'
            continue
        fi

        #######################################################################
        # Preserve comments
        #######################################################################

        if [[ "${line}" =~ ^[[:space:]]*# ]]; then
            output+="${line}"$'\n'
            continue
        fi

        #######################################################################
        # Ignore invalid lines
        #######################################################################

        [[ "${line}" == *=* ]] || continue

        #######################################################################
        # Parse variable
        #######################################################################

        key="${line%%=*}"
        example_value="${line#*=}"

        policy="$(env_variable_policy "${key}")"
        current_value="${ENV_CURRENT[$key]-}"

        #######################################################################
        # Apply policy
        #######################################################################

        case "${policy}" in

            framework)
                value="${example_value}"
                ;;

            user)

                if [[ -n "${current_value}" ]]; then
                    value="${current_value}"
                else
                    value="${example_value}"
                fi
                ;;

            generated)

                #
                # Keep a real secret. Replace only a missing value or a
                # set_* placeholder. Do not rotate a password that is
                # already in use.
                #

                if [[ -n "${current_value}" ]] \
                    && ! env_is_placeholder "${current_value}"; then

                    value="${current_value}"
                else
                    value="$(env_generate_secret_for "${key}")"
                    log_info "Generated ${key}."
                fi
                ;;

            *)

                fail "Unknown environment policy: ${policy}"
                ;;

        esac

        #######################################################################
        # Report differences
        #######################################################################

        if [[ "${policy}" == "user" ]] \
            && [[ -n "${current_value}" ]] \
            && [[ "${current_value}" != "${example_value}" ]]; then

            if env_is_sensitive "${key}"; then
                log_info "${key} differs. Keeping user value."
            else
                log_info "${key} differs"

                printf "       .env         : %s\n" "${current_value}"
                printf "       .env.example : %s\n" "${example_value}"
                printf "       Keeping user value.\n\n"
            fi

            #
            # NOTE: NOT "((differences++))" -- under "set -e",
            # a post-increment arithmetic expression returns
            # the PRE-increment value as its exit status. Going
            # from 0 to 1 evaluates to 0 ("false"), which makes
            # the whole script exit right here on the very
            # first difference found -- silently truncating
            # everything after it in the loop (this is exactly
            # what was happening: .env stopped being updated
            # right after the first differing variable).
            #

            differences=$((differences + 1))
        fi

        output+="${key}=${value}"$'\n'

    done < "${ENV_EXAMPLE_FILE}"

    ###########################################################################
    # Summary
    ###########################################################################

    if (( differences == 0 )); then
        log_success "No user variable differences found."
    elif (( differences == 1 )); then
        log_info "1 user variable differs from .env.example."
    else
        log_info "${differences} user variables differ from .env.example."
    fi

    env_write_file <<< "${output}"

    log_success ".env synchronized."
    log_warn "Placeholders that still start with set_ must be replaced before deploy.sh."
}
