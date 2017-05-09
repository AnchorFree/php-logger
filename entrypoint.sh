#!/usr/bin/env sh

export TEAM=${TEAM:-"default"}
export APPLICATION=${APPLICATION:-"php"}

# workaround until we get to named pipes
touch /log/php-error.log
touch /log/fpm-error.log
touch /log/slow.log
touch /log/app-error.json
touch /log/app-access.json

exec fluentd -c /fluentd/etc/$FLUENTD_CONF -p /fluentd/plugins $FLUENTD_OPT "$@"
