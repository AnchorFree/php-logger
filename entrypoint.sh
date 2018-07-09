#!/usr/bin/env bash

for i in php-error.log slow.log
do
    if [[ ! -p "/log/${i}" ]]; then
        rm -f /log/${i}
        mkfifo -m666 "/log/${i}"
    fi
done

exec /usr/sbin/syslog-ng -F "$@"
