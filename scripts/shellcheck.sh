#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/shellcheck.sh
#
# Description:
#   Run ShellCheck on all project shell scripts.
#
###############################################################################

set -euo pipefail

echo "Running ShellCheck..."

find scripts -name "*.sh" -print0 |
xargs -0 shellcheck \
    -x \
    -e SC1091 \
    -e SC2034

echo
echo "[ OK ] ShellCheck completed."