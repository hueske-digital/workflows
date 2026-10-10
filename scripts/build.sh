#!/bin/bash
# Builds an image with Buildah for one architecture and pushes it: the
# build step of image.yml and astro.yml, which pass their inputs in the
# environment (ARCH, IMAGE, CONTEXT, FILE, BUILD_ARGS, LABELS, TAGS, PUSH,
# RUNNER, SINGLE, FIRST_ARCH, STALE_DAYS, TOKEN and the run's of GitHub).
# BUILD_CONTEXTS, one name=directory a line, puts a directory in the
# place of a stage of the Dockerfile, which is then not built. With
# CHECK_ONLY it ends once it knows whether this run builds (the output
# built), before anything is built. With PUBLISH=false a single
# architecture is pushed as sha-<commit> only: the caller gives it the
# other tags of the output tags later.
set -euo pipefail
case $ARCH in
  amd64 | arm64) ;;
  *) echo "::error::arch $ARCH is none of amd64 and arm64"; exit 1 ;;
esac
case $RUNNER in
  self-hosted | github) ;;
  *) echo "::error::runner $RUNNER is none of self-hosted and github"; exit 1 ;;
esac
# A pull request's GITHUB_SHA is its merge commit.
sha=${PR_HEAD:-$GITHUB_SHA}
image=${IMAGE:-ghcr.io/${GITHUB_REPOSITORY,,}}
if ! [[ $image =~ ^ghcr\.io/[a-z0-9._/-]+$ ]]; then
  echo "::error::image $image is not a lower-case name on ghcr.io without a tag"
  exit 1
fi
# The default branch (a scheduled run is one of it) and a tag.
trusted=''
if [ "$GITHUB_EVENT_NAME" = schedule ] || { [ "$GITHUB_REF_TYPE" = branch ] && [ "$GITHUB_REF_NAME" = "$DEFAULT_BRANCH" ]; }; then
  trusted=default
elif [ "$GITHUB_REF_TYPE" = tag ]; then
  trusted=tag
fi
tags=("sha-${sha::7}")
if [ -n "$TAGS" ]; then
  while IFS= read -r t; do [ -z "$t" ] || tags+=("$t"); done <<< "$TAGS"
else
  [ "$trusted" != default ] || tags+=(latest)
  [ "$trusted" != tag ] || tags+=("$GITHUB_REF_NAME")
fi
for t in "${tags[@]}"; do
  # An image tag: letters, digits, _ . - and at most 128 of them.
  if ! [[ $t =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    echo "::error::$t is no image tag"
    exit 1
  fi
done
echo "image=$image" >> "$GITHUB_OUTPUT"
echo "tags=${tags[*]}" >> "$GITHUB_OUTPUT"
file=${FILE:-$CONTEXT/Dockerfile}
# Also without push: the cache of a private image is read with it.
printf '%s' "$TOKEN" | buildah login --username "$GITHUB_ACTOR" --password-stdin ghcr.io
# One hash over the digest of every image the Dockerfile builds
# FROM, kept as a label: a scheduled run compares it with the
# label of latest. A digest is the hash of what the tag names
# (the index of an image for several platforms). A FROM that
# names an earlier stage is none, and one with a variable is not
# known here: such a Dockerfile is built by every run.
bases=''
if command -v skopeo > /dev/null; then
  list='' stages=' '
  while read -r ref stage; do
    case "$stages" in *" $ref "*) continue ;; esac
    [ -z "$stage" ] || stages+="$stage "
    [ "$ref" != scratch ] || continue
    case $ref in *'$'*) list=unknown; break ;; esac
    list+="$ref@sha256:$(skopeo inspect --raw "docker://$ref" | sha256sum | cut -d' ' -f1)"$'\n'
  done < <(awk 'toupper($1) == "FROM" { ref = ""; stage = ""; for (i = 2; i <= NF; i++) { if ($i ~ /^--/) continue; if (ref == "") { ref = $i; continue } if (toupper($i) == "AS") { stage = $(i + 1); break } } print ref, stage }' "$file")
  if [ "$list" != unknown ]; then
    printf '%s' "$list"
    bases=$(printf '%s' "$list" | sha256sum | cut -d' ' -f1)
  fi
else
  echo "::warning::no skopeo on this runner: the base images are not recorded"
fi
# Every architecture reads the same one of latest and the same
# day, so that all of them build or none.
if [ "$GITHUB_EVENT_NAME" = schedule ] && [ "$PUSH" = true ] && [ -n "$bases" ] && [ "$STALE_DAYS" -gt 0 ]; then
  latest=$(skopeo inspect --no-tags --override-os linux --override-arch "$FIRST_ARCH" "docker://$image:latest" 2> /dev/null || echo '{}')
  was=$(jq -r '.Labels["digital.hueske.workflows.bases"] // empty' <<< "$latest")
  age=$(jq -r '(now / 86400 | floor) - ((.Created // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+"; "") | fromdateiso8601 / 86400 | floor)' <<< "$latest")
  if [ "$was" = "$bases" ] && [ "$age" -lt "$STALE_DAYS" ]; then
    echo "The base images are unchanged and latest is $age days old: nothing to build." | tee -a "$GITHUB_STEP_SUMMARY"
    echo "built=false" >> "$GITHUB_OUTPUT"
    exit 0
  fi
fi
echo "built=true" >> "$GITHUB_OUTPUT"
[ "${CHECK_ONLY:-}" != true ] || exit 0
# The docker format: Buildah's default, oci, drops a Dockerfile's
# HEALTHCHECK and runs no RUN with its SHELL. The cache is read
# by every build and written by those of the default branch and
# of tags only: a step in it is used by every later build.
args=(--format docker --layers --platform "linux/$ARCH" --file "$file" --cache-from "$image/cache"
  --label "org.opencontainers.image.source=$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
  --label "org.opencontainers.image.revision=$sha")
while IFS= read -r line; do [ -z "$line" ] || args+=(--build-arg "$line"); done <<< "$BUILD_ARGS"
while IFS= read -r line; do [ -z "$line" ] || args+=(--label "$line"); done <<< "$LABELS"
[ -z "$bases" ] || args+=(--label "digital.hueske.workflows.bases=$bases")
while IFS= read -r line; do [ -z "$line" ] || args+=(--build-context "$line"); done <<< "${BUILD_CONTEXTS:-}"
if [ "$PUSH" = true ] && [ -n "$trusted" ]; then
  args+=(--cache-to "$image/cache")
fi
buildah build "${args[@]}" --tag "$image:build" "$CONTEXT"
[ "$PUSH" = true ] || exit 0
if [ "$SINGLE" = true ]; then
  [ "${PUBLISH:-true}" = true ] || tags=("${tags[0]}")
  for t in "${tags[@]}"; do
    buildah push --digestfile "$RUNNER_TEMP/digest" "$image:build" "docker://$image:$t"
  done
  echo "digest=$(cat "$RUNNER_TEMP/digest")" >> "$GITHUB_OUTPUT"
  echo "$image@$(cat "$RUNNER_TEMP/digest") as ${tags[*]}" >> "$GITHUB_STEP_SUMMARY"
else
  buildah push "$image:build" "docker://$image:${tags[0]}-$ARCH"
fi
