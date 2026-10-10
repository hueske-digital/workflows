# The stage build writes who built; image.yml's test puts a directory of the
# runner in its place. The store listing shows that the runner's pnpm
# store is in a RUN of the build.
FROM public.ecr.aws/docker/library/alpine:3.22 AS build
RUN mkdir /out && echo "the Dockerfile" > /out/built-by

FROM public.ecr.aws/docker/library/alpine:3.22
RUN ls /pnpm/store 2> /dev/null | head -1 > /store || true
COPY --from=build /out/ /app/
CMD ["sh", "-c", "cat /app/built-by; test -s /store && echo store"]
