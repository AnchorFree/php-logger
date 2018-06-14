#!/usr/bin/env bash

if [[ ! -p "/log/slow.log" ]]; then
    mkfifo -m666 "/log/slow.log"
fi

exec /usr/sbin/syslog-ng -F "$@"
