#!/usr/bin/env bash


[[ ! -d /log  ]] && mkdir /log

for i in php-error.log fpm-error.log slow.log app-error.json app-access.json
do
    if [[ ! -f /log/${i} ]]; then
        rm -fr /log/${i}
        > /log/${i}
    fi
    chmod 0666 /log/${i}
done

exec /usr/sbin/syslog-ng -F "$@"
