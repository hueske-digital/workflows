FROM public.ecr.aws/docker/library/alpine:3.22
ARG GREETING=hello
RUN apk add --no-cache curl
RUN echo "$GREETING" > /greeting
CMD ["cat", "/greeting"]
