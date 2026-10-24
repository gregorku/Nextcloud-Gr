#!/bin/sh
#
# Nextcloud-Gr
#
# The official 35.0.2-fpm image already ships apcu.config.php and
# redis.config.php. This hook records memcache.local in config.php so
# the backed-up configuration still names APCu if those image files are
# compared or replaced during an upgrade.
#
# It runs as root from the image entrypoint, after installation and
# after the image upgrade. It does not print Redis or database secrets.

set -eu

su -s /bin/bash www-data -c "php /var/www/html/occ config:system:set memcache.local --value='\\OC\\Memcache\\APCu'"
su -s /bin/bash www-data -c "php /var/www/html/occ config:system:set memcache.distributed --value='\\OC\\Memcache\\Redis'"
su -s /bin/bash www-data -c "php /var/www/html/occ config:system:set memcache.locking --value='\\OC\\Memcache\\Redis'"
