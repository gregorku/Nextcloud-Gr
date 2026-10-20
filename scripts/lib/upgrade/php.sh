#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/upgrade/php.sh
#
# Description:
#   PHP versions that this repository has checked against the Nextcloud
#   administration manual for one major series. A major that is not
#   listed here is refused. The list is not a standing rule for every
#   future Nextcloud release.
#
#   Nextcloud 35: PHP 8.3, 8.4 and 8.5 (8.5 recommended).
#   Source: https://docs.nextcloud.com/server/35/admin_manual/installation/system_requirements.html
#   Checked on 2026-10-20.
#
###############################################################################

upgrade_php_major_is_known()
{
    case "$1" in
        35)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

###############################################################################
# 0 when this major's verified matrix contains the PHP version.
# 1 when the major is known and the PHP version is outside it.
# 2 when this repository has no verified matrix for the major.
#
# Arguments:
#   $1 - Nextcloud major
#   $2 - PHP version string from the image, such as 8.5.1
#
###############################################################################

upgrade_php_is_supported()
{
    local major="$1"
    local php_version="$2"

    upgrade_php_major_is_known "${major}" || return 2

    case "${major}" in
        35)
            [[ "${php_version}" =~ ^8\.(3|4|5)\.[0-9]+$ ]]
            ;;
        *)
            return 2
            ;;
    esac
}
