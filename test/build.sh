#!/bin/bash
# Runs scripts/build.sh with a buildah and a skopeo of its own
# (no registry, no build) and checks what it decides: when a run builds (a
# scheduled one only for a changed base image or an old one), which images
# of a Dockerfile count as its bases, the tags and where latest is, the
# version, the layer cache, and that a build secret is a file that goes.
# Needs jq and GNU date.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp scripts/build.sh "$work/step.sh"
mkdir "$work/bin" "$work/ctx"
# buildah: every call is a line of the log, a push writes its digest file.
cat > "$work/bin/buildah" <<'STUB'
#!/bin/bash
echo "buildah $*" >> "$LOG"
while [ $# -gt 0 ]; do
  [ "$1" != --digestfile ] || echo sha256:0000 > "$2"
  shift
done
STUB
# skopeo: a base image's manifest is its name and BASE_VERSION; the image
# built before is STUB_LATEST, or missing without it.
cat > "$work/bin/skopeo" <<'STUB'
#!/bin/bash
echo "skopeo $*" >> "$LOG"
case " $* " in
  *" --raw "*) echo "manifest of ${*: -1} $BASE_VERSION" ;;
  *) [ -n "$STUB_LATEST" ] || exit 1; echo "$STUB_LATEST" ;;
esac
STUB
chmod +x "$work/bin/buildah" "$work/bin/skopeo"

failed=0
# run <event> <stale-days>: the step's outputs in $work/out, its calls in $work/log.
run() {
  : > "$work/log"; : > "$work/out"
  env PATH="$work/bin:$PATH" LOG="$work/log" GITHUB_OUTPUT="$work/out" GITHUB_STEP_SUMMARY=/dev/null RUNNER_TEMP="$work" \
    GITHUB_EVENT_NAME="$1" STALE_DAYS="$2" GITHUB_REPOSITORY=hueske-digital/demo GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
    GITHUB_REF_TYPE="${REF_TYPE:-branch}" GITHUB_REF_NAME="${REF_NAME:-main}" DEFAULT_BRANCH=main GITHUB_ACTOR=test GITHUB_SERVER_URL=https://github.com \
    ARCH=amd64 FIRST_ARCH=amd64 SINGLE=true RUNNER=github PUSH=true TOKEN=t IMAGE= CONTEXT="$work/ctx" FILE= BUILD_ARGS="${ARGS:-}" LABELS= TAGS= PR_HEAD= \
    LATEST="${LATEST_ON:-branch}" BUILD_SECRETS="${SECRETS:-}" CACHE="${CACHE_IN:-registry}" \
    PATHS="${PATHS_IN:-}" BEFORE="${BEFORE_IN:-}" PR_BASE="${PR_BASE_IN:-}" \
    BASE_VERSION="${BASE_VERSION:-1}" STUB_LATEST="${STUB_LATEST:-}" bash "$work/step.sh" > "$work/stdout" 2>&1 || [ -n "${MAY_FAIL:-}" ] || { echo "FAILED: the step ended with $?"; cat "$work/stdout"; failed=1; }
}
# expect <name> <built>: the output built, and a build exactly when it is true.
expect() {
  local built
  built=$(sed -n 's/^built=//p' "$work/out")
  if [ "$built" != "$2" ] || { [ "$2" = true ] && ! grep -q '^buildah build ' "$work/log"; } || { [ "$2" = false ] && grep -q '^buildah build \|^buildah push ' "$work/log"; }; then
    echo "FAILED: $1: built=$built, wanted $2"; cat "$work/log"; failed=1
  else
    echo "ok: $1"
  fi
}
latest() { jq -cn --arg bases "$1" --arg created "$2" '{Created: $created, Labels: {"digital.hueske.workflows.bases": $bases}}'; }
now=$(date -u +%Y-%m-%dT%H:%M:%S.123456789Z)

printf 'FROM docker.io/library/alpine:3\nRUN true\n' > "$work/ctx/Dockerfile"
run push 7; expect "a push builds" true
bases=$(grep -o 'digital.hueske.workflows.bases=[0-9a-f]*' "$work/log" | cut -d= -f2)
[ ${#bases} = 64 ] || { echo "FAILED: no label of the bases in: $(cat "$work/log")"; failed=1; }

STUB_LATEST=$(latest "$bases" "$now") run schedule 7; expect "scheduled, the same base and a young latest" false
STUB_LATEST=$(latest "$bases" "$now") run push 7; expect "a push builds whatever latest is" true
STUB_LATEST=$(latest "$bases" "$now") BASE_VERSION=2 run schedule 7; expect "scheduled, a changed base" true
STUB_LATEST=$(latest "$bases" "$(date -u -d '8 days ago' +%Y-%m-%dT%H:%M:%SZ)") run schedule 7; expect "scheduled, latest 8 days old" true
STUB_LATEST=$(latest "$bases" "$(date -u -d '6 days ago' +%Y-%m-%dT%H:%M:%SZ)") run schedule 7; expect "scheduled, latest 6 days old" false
STUB_LATEST=$(latest "$bases" "$now") run schedule 0; expect "scheduled, stale-days 0" true
run schedule 7; expect "scheduled, no latest yet" true
STUB_LATEST='{"Created": "'"$now"'", "Labels": null}' run schedule 7; expect "scheduled, a latest without the label" true

# The tags of a run, and where latest is.
pushed() { grep '^buildah push ' "$work/log" | sed 's/.*://' | tr '\n' ' '; }
tagged() {
  if [ "$(pushed)" = "$2 " ]; then echo "ok: $1"; else echo "FAILED: $1: pushed $(pushed), wanted $2"; failed=1; fi
}
REF_TYPE=tag REF_NAME=v1.2.3 run push 7; tagged "a version tag" "sha-0123456 1.2.3 1.2"
REF_TYPE=tag REF_NAME=1.2.3 LATEST_ON=release run push 7; tagged "a version tag without v, latest on releases" "sha-0123456 1.2.3 1.2 latest"
REF_TYPE=tag REF_NAME=nightly run push 7; tagged "another tag" "sha-0123456 nightly"
LATEST_ON=release run push 7; tagged "the default branch, latest on releases" "sha-0123456 main"
REF_NAME=feature/x run push 7; tagged "another branch" "sha-0123456"
STUB_LATEST=$(latest "$bases" "$now") LATEST_ON=release run schedule 7
if grep -q 'docker://ghcr.io/hueske-digital/demo:main$' "$work/log"; then
  echo "ok: scheduled, latest on releases: compared with the branch's tag"
else
  echo "FAILED: $(grep '^skopeo inspect .*--no-tags' "$work/log")"; failed=1;
fi

# The layer cache: every instruction a layer and the registry asked and
# written, or one layer a stage and no registry.
run push 7
if grep -q -- '^buildah build --layers --cache-from ghcr.io/hueske-digital/demo/cache .*--cache-to ghcr.io/hueske-digital/demo/cache' "$work/log"; then
  echo "ok: the registry cache is read and, on the default branch, written"
else
  echo "FAILED: $(grep '^buildah build' "$work/log")"; failed=1
fi
REF_NAME=feature/x run push 7
if grep -q -- '--cache-from' "$work/log" && ! grep -q -- '--cache-to' "$work/log"; then
  echo "ok: another branch reads the registry cache only"
else
  echo "FAILED: $(grep '^buildah build' "$work/log")"; failed=1
fi
CACHE_IN=none run push 7
if grep -q -- '^buildah build --layers=false ' "$work/log" && ! grep -q -- '--cache-' "$work/log"; then
  echo "ok: without a layer cache"
else
  echo "FAILED: $(grep '^buildah build' "$work/log")"; failed=1
fi

# paths: a push or a pull request builds only when a file of them changed.
repo=$work/repo
git init -q "$repo"
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m first
mkdir -p "$repo/apps/site" "$repo/docs"
echo a > "$repo/apps/site/page"; echo a > "$repo/docs/readme.md"
git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m site
first=$(git -C "$repo" rev-parse HEAD~1) site=$(git -C "$repo" rev-parse HEAD)
echo b > "$repo/docs/readme.md"
git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m docs
cd "$repo"
PATHS_IN=apps/site BEFORE_IN=$site run push 7; expect "paths: a push that changed none of them" false
PATHS_IN=apps/site BEFORE_IN=$first run push 7; expect "paths: a push that changed one of them" true
PATHS_IN=$'apps/site\ndocs' BEFORE_IN=$site run push 7; expect "paths: the second of two changed" true
PATHS_IN=$'.\n:(exclude)*.md' BEFORE_IN=$site run push 7; expect "paths: everything but what is excluded" false
PATHS_IN=apps/site PR_BASE_IN=$site REF_NAME=7/merge run pull_request 7; expect "paths: a pull request against its base" false
PATHS_IN=apps/site BEFORE_IN=0000000000000000000000000000000000000000 run push 7; expect "paths: a new branch builds" true
PATHS_IN=apps/site BEFORE_IN=1111111111111111111111111111111111111111 run push 7; expect "paths: a commit that is gone builds" true
PATHS_IN=apps/site BEFORE_IN=$site REF_TYPE=tag REF_NAME=v1.2.3 run push 7; expect "paths: a tag builds" true
PATHS_IN=apps/site BEFORE_IN=$site run workflow_dispatch 7; expect "paths: a run by hand builds" true
BEFORE_IN=$site run push 7; expect "without paths every push builds" true
cd "$OLDPWD"

# {version} in a build argument.
REF_TYPE=tag REF_NAME=v1.2.3 ARGS='APP_VERSION=app@{version}' run push 7
if grep -q -- '--build-arg APP_VERSION=app@1.2.3 ' "$work/log" && grep -q '^version=1.2.3$' "$work/out"; then
  echo "ok: {version} of a release"
else
  echo "FAILED: $(grep '^buildah build' "$work/log")"; failed=1;
fi
REF_NAME=41/merge ARGS='APP_VERSION=app@{version}' run pull_request 7
if grep -q -- '--build-arg APP_VERSION=app@pr-41 ' "$work/log"; then
  echo "ok: {version} of a pull request"
else
  echo "FAILED: $(grep '^buildah build' "$work/log")"; failed=1;
fi

# A build secret is a file for the build and gone after it; one without a
# value is not given; nothing of it is in the output but the mask.
SECRETS=$'TOKEN=s3cr3t-value\nEMPTY=' run push 7
if grep -q -- '--secret id=TOKEN,src=' "$work/log" && ! grep -q 'id=EMPTY' "$work/log" && ! ls "$work"/secrets.* > /dev/null 2>&1 \
  && ! grep -q 's3cr3t-value' "$work/log" && [ "$(grep -c 's3cr3t-value' "$work/stdout")" = 1 ] && grep -q '^::add-mask::s3cr3t-value$' "$work/stdout"; then
  echo "ok: a build secret"
else
  echo "FAILED: a build secret: $(grep '^buildah build' "$work/log"; ls "$work"; grep -c 's3cr3t-value' "$work/stdout")"; failed=1
fi
SECRETS='no equals sign' MAY_FAIL=1 run push 7
if grep -q 'a build secret is ID=value' "$work/stdout" && ! grep -q '^buildah build' "$work/log"; then
  echo "ok: a malformed build secret is refused, unprinted"
else
  echo "FAILED: malformed secret"; failed=1;
fi
# Stages and flags: only the two images from outside are asked for.
printf 'FROM --platform=linux/amd64 docker.io/library/golang:1 AS build\nRUN true\nFROM build AS test\nFROM scratch AS empty\nfrom docker.io/library/alpine:3\nCOPY --from=build /x /x\n' > "$work/ctx/Dockerfile"
run push 7
asked=$(grep -c '^skopeo inspect .*--raw' "$work/log" || true)
if [ "$asked" = 2 ] && grep -q 'golang:1$' "$work/log" && grep -q 'alpine:3$' "$work/log"; then echo "ok: stages, scratch and flags are no base images"; else echo "FAILED: asked for $asked base images: $(grep '^skopeo' "$work/log")"; failed=1; fi

# A base named by a variable is not known: no label, and every run builds.
# shellcheck disable=SC2016 # the Dockerfile's own variable, not the shell's
printf 'ARG BASE=docker.io/library/alpine:3\nFROM ${BASE}\n' > "$work/ctx/Dockerfile"
STUB_LATEST=$(latest "$bases" "$now") run schedule 7; expect "scheduled, a base named by a variable" true
if grep -q 'digital.hueske.workflows.bases' "$work/log"; then echo "FAILED: a label for an unknown base"; failed=1; else echo "ok: no label for an unknown base"; fi

exit "$failed"
