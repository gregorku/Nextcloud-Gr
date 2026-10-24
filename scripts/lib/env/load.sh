#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/env/load.sh
#
# Description:
#   Load environment library.
#
###############################################################################

source "${SCRIPT_DIR}/lib/env/constants.sh"

source "${SCRIPT_DIR}/lib/env/helpers.sh"

source "${SCRIPT_DIR}/lib/env/parser.sh"

source "${SCRIPT_DIR}/lib/env/reader.sh"

source "${SCRIPT_DIR}/lib/env/policy.sh"

source "${SCRIPT_DIR}/lib/env/generate.sh"

source "${SCRIPT_DIR}/lib/env/writer.sh"

source "${SCRIPT_DIR}/lib/env/sync.sh"

source "${SCRIPT_DIR}/lib/env/validate.sh"