FROM alpine:3.20

RUN apk add --no-cache mosquitto-clients openssl ca-certificates

COPY publish-ice.sh /usr/local/bin/publish-ice.sh
RUN chmod +x /usr/local/bin/publish-ice.sh

ENTRYPOINT ["/usr/local/bin/publish-ice.sh"]
