FROM fluent/fluentd:v0.12

COPY ./fluent.conf /fluentd/etc/fluent.conf
