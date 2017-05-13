FROM fluent/fluentd:v0.12

COPY ./fluent.conf /fluentd/etc/fluent.conf
COPY ./entrypoint.sh /entrypoint.sh
COPY ./plugins/* /fluentd/plugins/
USER root
RUN apk add --update \
    ruby-dev \
    ruby-rake \
    make \ 
    gcc \
    build-base 

RUN gem install --no-user-install ruby-fifo -v 0.0.1

ENTRYPOINT ["/entrypoint.sh"]
CMD []
