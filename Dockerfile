FROM alpine:latest
COPY overdrive.sh /
RUN chmod +x overdrive.sh && \
  apk add --no-cache \
    bash \
    curl \
    libxml2-utils \
    openssl \
    tidyhtml \
    util-linux && \
  mkdir /data
WORKDIR "/data"
USER 1000:1000
VOLUME "/data"
ENTRYPOINT ["/overdrive.sh"]
