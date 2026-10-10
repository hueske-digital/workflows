#!/bin/bash
# Builds an image with Buildah for one architecture and pushes it: the
# build step of image.yml and astro.yml, which pass their inputs in the
# environment (ARCH, IMAGE, CONTEXT, FILE, BUILD_ARGS, LABELS, TAGS, PUSH,
# RUNNER, SINGLE, FIRST_ARCH, STALE_DAYS, TOKEN and the run's of GitHub;
# LATEST, BUILD_SECRETS and PATHS with BEFORE and PR_BASE where a workflow
# has them).
# BUILD_VOLUMES, one directory:path a line, is in every RUN of the build
# at that path. BUILD_CONTEXTS, one name=directory a line, puts a directory in the
# place of a stage of the Dockerfile, which is then not built. With
# CHECK_ONLY it ends once it knows whether this run builds (the output
# built), before anything is built.
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
# What the run builds: a pushed version tag (1.2.3 or v1.2.3) is a release
# and its version the tag without the v; else the tag, the pull request or
# the branch.
release=false minor=''
if [ "$GITHUB_REF_TYPE" = tag ] && [[ $GITHUB_REF_NAME =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  release=true version=${GITHUB_REF_NAME#v} minor="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
elif [ "$GITHUB_REF_TYPE" = tag ]; then
  version=$GITHUB_REF_NAME
elif [ "$GITHUB_EVENT_NAME" = pull_request ]; then
  version=pr-${GITHUB_REF_NAME%%/*}
else
  version=${GITHUB_REF_NAME//\//-}
fi
# Where latest is: on the default branch, or on the newest release, with
# the default branch under its own name then.
latest=${LATEST:-branch}
case $latest in
  branch | release) ;;
  *) echo "::error::latest $latest is none of branch and release"; exit 1 ;;
esac
# The tag a scheduled run compares with: what the default branch built.
follows=latest
[ "$latest" != release ] || follows=$version
tags=("sha-${sha::7}")
if [ -n "$TAGS" ]; then
  while IFS= read -r t; do [ -z "$t" ] || tags+=("$t"); done <<< "$TAGS"
elif [ "$release" = true ]; then
  tags+=("$version" "$minor")
  [ "$latest" != release ] || tags+=(latest)
elif [ "$trusted" = tag ]; then
  tags+=("$GITHUB_REF_NAME")
elif [ "$trusted" = default ]; then
  tags+=("$follows")
fi
for t in "${tags[@]}"; do
  # An image tag: letters, digits, _ . - and at most 128 of them.
  if ! [[ $t =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    echo "::error::$t is no image tag"
    exit 1
  fi
done
{
  echo "image=$image"
  echo "tags=${tags[*]}"
  echo "version=$version"
} >> "$GITHUB_OUTPUT"
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
    list+="$ref@sha256:$(skopeo inspect --retry-times 3 --raw "docker://$ref" | sha256sum | cut -d' ' -f1)"$'\n'
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
  last=$(skopeo inspect --retry-times 3 --no-tags --override-os linux --override-arch "$FIRST_ARCH" "docker://$image:$follows" 2> /dev/null || echo '{}')
  was=$(jq -r '.Labels["digital.hueske.workflows.bases"] // empty' <<< "$last")
  age=$(jq -r '(now / 86400 | floor) - ((.Created // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+"; "") | fromdateiso8601 / 86400 | floor)' <<< "$last")
  if [ "$was" = "$bases" ] && [ "$age" -lt "$STALE_DAYS" ]; then
    echo "The base images are unchanged and $follows is $age days old: nothing to build." | tee -a "$GITHUB_STEP_SUMMARY"
    echo "built=false" >> "$GITHUB_OUTPUT"
    exit 0
  fi
fi
# With PATHS (git pathspecs, one a line) a push or a pull request builds
# only when a file of them changed: since the commit before the push, or
# against the pull request's base. A tag, a run by hand, a scheduled run
# and a push without a commit before it (a new branch, a forced push whose
# old commit is gone) build as without PATHS, and so does a comparison
# that fails: rather a build too many than an image that stays old.
if [ -n "${PATHS:-}" ] && [ "$GITHUB_REF_TYPE" != tag ]; then
  base=''
  case $GITHUB_EVENT_NAME in
    push) base=${BEFORE:-} ;;
    pull_request) base=${PR_BASE:-} ;;
  esac
  if [[ $base =~ ^[0-9a-f]{40}$ ]] && [ "$base" != 0000000000000000000000000000000000000000 ]; then
    specs=()
    while IFS= read -r line; do [ -z "$line" ] || specs+=("$line"); done <<< "$PATHS"
    # The checkout holds one commit: the other one is fetched alone, with
    # the run's token for a private repository.
    if ! git cat-file -e "$base^{commit}" 2> /dev/null; then
      git -c "http.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')" \
        fetch --quiet --no-tags --depth=1 origin "$base" 2> /dev/null || true
    fi
    changed=0
    git diff --quiet "$base" HEAD -- "${specs[@]}" 2> /dev/null || changed=$?
    if [ "$changed" = 0 ]; then
      echo "Nothing of paths changed since ${base::7}: nothing to build." | tee -a "$GITHUB_STEP_SUMMARY"
      echo "built=false" >> "$GITHUB_OUTPUT"
      exit 0
    fi
  fi
fi
echo "built=true" >> "$GITHUB_OUTPUT"
[ "${CHECK_ONLY:-}" != true ] || exit 0
# The docker format: Buildah's default, oci, drops a Dockerfile's
# HEALTHCHECK and runs no RUN with its SHELL. The cache is read
# by every build and written by those of the default branch and
# of tags only: a step in it is used by every later build.
# CACHE=registry keeps a layer for every instruction and reads and writes
# them in the registry: worth it for a RUN that takes long. Each instruction
# then costs a comparison of the whole file tree and a pull or a push of its
# own, so that CACHE=none, one layer for the stage and no registry, is
# faster for a Dockerfile whose stages copy and configure.
cache=${CACHE:-registry}
case $cache in
  registry) args=(--layers --cache-from "$image/cache") ;;
  none) args=(--layers=false) ;;
  *) echo "::error::cache $cache is none of registry and none"; exit 1 ;;
esac
args+=(--format docker --platform "linux/$ARCH" --file "$file"
  --label "org.opencontainers.image.source=$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
  --label "org.opencontainers.image.revision=$sha")
# {version} in a build argument or a label is the version of above.
while IFS= read -r line; do [ -z "$line" ] || args+=(--build-arg "${line//\{version\}/$version}"); done <<< "$BUILD_ARGS"
while IFS= read -r line; do [ -z "$line" ] || args+=(--label "${line//\{version\}/$version}"); done <<< "$LABELS"
[ -z "$bases" ] || args+=(--label "digital.hueske.workflows.bases=$bases")
# A directory of the repository is named from its root.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  name=${line%%=*} dir=${line#*=}
  case $dir in /*) ;; *) dir=$GITHUB_WORKSPACE/$dir ;; esac
  [ -d "$dir" ] || { echo "::error::the build context $name is no directory: $dir"; exit 1; }
  args+=(--build-context "$name=$dir")
done <<< "${BUILD_CONTEXTS:-}"
while IFS= read -r line; do [ -z "$line" ] || args+=(--volume "$line"); done <<< "${BUILD_VOLUMES:-}"
if [ "$cache" = registry ] && [ "$PUSH" = true ] && [ -n "$trusted" ]; then
  args+=(--cache-to "$image/cache")
fi
# A build secret, ID=value a line, reaches the build as a file that a RUN
# of the Dockerfile mounts (--mount=type=secret,id=ID, at /run/secrets/ID)
# and is in no layer. One without a value is not given. No line of them is
# ever printed.
secrets=$(mktemp -d "$RUNNER_TEMP/secrets.XXXXXX")
trap 'rm -rf "$secrets"' EXIT
while IFS= read -r line; do
  [ -n "$line" ] || continue
  id=${line%%=*} value=${line#*=}
  if [[ $line != *=* ]] || ! [[ $id =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
    echo "::error::a build secret is ID=value, one a line"
    exit 1
  fi
  [ -n "$value" ] || continue
  echo "::add-mask::$value"
  (umask 077 && printf '%s' "$value" > "$secrets/$id")
  args+=(--secret "id=$id,src=$secrets/$id")
done <<< "${BUILD_SECRETS:-}"
buildah build "${args[@]}" --tag "$image:build" "$CONTEXT"
[ "$PUSH" = true ] || exit 0
if [ "$SINGLE" = true ]; then
  for t in "${tags[@]}"; do
    buildah push --digestfile "$RUNNER_TEMP/digest" "$image:build" "docker://$image:$t"
  done
  echo "digest=$(cat "$RUNNER_TEMP/digest")" >> "$GITHUB_OUTPUT"
  echo "$image@$(cat "$RUNNER_TEMP/digest") as ${tags[*]}" >> "$GITHUB_STEP_SUMMARY"
else
  buildah push "$image:build" "docker://$image:${tags[0]}-$ARCH"
fi
