#!/usr/bin/env sh

export TEAM=${TEAM:-"default"}
export APPLICATION=${APPLICATION:-"php"}

exec fluentd -c /fluentd/etc/$FLUENTD_CONF -p /fluentd/plugins $FLUENTD_OPT "$@"
