FROM golang:1.10.1

ENV BASE_DIR /go/src/php-logger

ADD . ${BASE_DIR}

RUN cd ${BASE_DIR} \
    && go test && CGO_ENABLED=0 GOOS=linux go build -a -tags netgo -ldflags '-w'

FROM alpine
COPY --from=0 /go/src/php-logger /bin/php-logger
COPY --from=0 /go/src/php-logger/config.yaml /etc/config.yaml

WORKDIR /etc
ENTRYPOINT ["/bin/php-logger"]
