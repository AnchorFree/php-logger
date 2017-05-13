#!/usr/bin/env sh

export TEAM=${TEAM:-"default"}
export APPLICATION=${APPLICATION:-"php"}

# create named pipes before using them
for i in php-error.log fpm-error.log slow.log app-error.json app-access.json
do
    if [[ ! -p "/log/${i}" ]]; then
        mkfifo -m666 "/log/${i}"
    fi
done

exec fluentd -c /fluentd/etc/$FLUENTD_CONF -p /fluentd/plugins $FLUENTD_OPT "$@"
