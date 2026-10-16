FROM docker.io/library/alpine:3.22
ARG GREETING=hello
RUN apk add --no-cache curl
RUN echo "$GREETING" > /greeting
# A build secret is a file for this RUN only: its length is kept, as proof
# that it arrived, and nothing of it.
RUN --mount=type=secret,id=PROOF wc -c < /run/secrets/PROOF > /proof-length
CMD ["cat", "/greeting"]
