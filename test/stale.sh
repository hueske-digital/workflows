#!/bin/bash
# Runs scripts/build.sh with a buildah and a skopeo of its own
# (no registry, no build) and checks when a run builds: a scheduled one
# only for a changed base image or a latest of stale-days, every other
# always; and which images of a Dockerfile count as its bases.
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
# skopeo: a base image's manifest is its name and BASE_VERSION; latest is
# LATEST, or missing without it.
cat > "$work/bin/skopeo" <<'STUB'
#!/bin/bash
echo "skopeo $*" >> "$LOG"
case " $* " in
  *" --raw "*) echo "manifest of ${*: -1} $BASE_VERSION" ;;
  *) [ -n "$LATEST" ] || exit 1; echo "$LATEST" ;;
esac
STUB
chmod +x "$work/bin/buildah" "$work/bin/skopeo"

failed=0
# run <event> <stale-days>: the step's outputs in $work/out, its calls in $work/log.
run() {
  : > "$work/log"; : > "$work/out"
  env PATH="$work/bin:$PATH" LOG="$work/log" GITHUB_OUTPUT="$work/out" GITHUB_STEP_SUMMARY=/dev/null RUNNER_TEMP="$work" \
    GITHUB_EVENT_NAME="$1" STALE_DAYS="$2" GITHUB_REPOSITORY=hueske-digital/demo GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
    GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main DEFAULT_BRANCH=main GITHUB_ACTOR=test GITHUB_SERVER_URL=https://github.com \
    ARCH=amd64 FIRST_ARCH=amd64 SINGLE=true RUNNER=github PUSH=true TOKEN=t IMAGE= CONTEXT="$work/ctx" FILE= BUILD_ARGS= LABELS= TAGS= PR_HEAD= \
    BASE_VERSION="${BASE_VERSION:-1}" LATEST="${LATEST:-}" PUBLISH="${PUBLISH:-true}" bash "$work/step.sh" > "$work/stdout" 2>&1 || { echo "FAILED: the step ended with $?"; cat "$work/stdout"; failed=1; }
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

LATEST=$(latest "$bases" "$now") run schedule 7; expect "scheduled, the same base and a young latest" false
LATEST=$(latest "$bases" "$now") run push 7; expect "a push builds whatever latest is" true
LATEST=$(latest "$bases" "$now") BASE_VERSION=2 run schedule 7; expect "scheduled, a changed base" true
LATEST=$(latest "$bases" "$(date -u -d '8 days ago' +%Y-%m-%dT%H:%M:%SZ)") run schedule 7; expect "scheduled, latest 8 days old" true
LATEST=$(latest "$bases" "$(date -u -d '6 days ago' +%Y-%m-%dT%H:%M:%SZ)") run schedule 7; expect "scheduled, latest 6 days old" false
LATEST=$(latest "$bases" "$now") run schedule 0; expect "scheduled, stale-days 0" true
run schedule 7; expect "scheduled, no latest yet" true
LATEST='{"Created": "'"$now"'", "Labels": null}' run schedule 7; expect "scheduled, a latest without the label" true

# A single architecture is pushed under every tag, and under sha-<commit>
# alone when the caller gives it the others later.
run push 7
[ "$(grep -c '^buildah push ' "$work/log")" = 2 ] && grep -q ':latest$' "$work/log" && echo "ok: pushed as sha and latest" || { echo "FAILED: $(grep '^buildah push' "$work/log")"; failed=1; }
PUBLISH=false run push 7
[ "$(grep -c '^buildah push ' "$work/log")" = 1 ] && grep -q '^buildah push .*:sha-0123456$' "$work/log" && grep -q '^tags=sha-0123456 latest$' "$work/out" && echo "ok: without publish pushed as sha only, the tags named" || { echo "FAILED: $(grep '^buildah push' "$work/log"; cat "$work/out")"; failed=1; }

# Stages and flags: only the two images from outside are asked for.
printf 'FROM --platform=linux/amd64 docker.io/library/golang:1 AS build\nRUN true\nFROM build AS test\nFROM scratch AS empty\nfrom docker.io/library/alpine:3\nCOPY --from=build /x /x\n' > "$work/ctx/Dockerfile"
run push 7
asked=$(grep -c '^skopeo inspect --raw' "$work/log" || true)
if [ "$asked" = 2 ] && grep -q 'golang:1$' "$work/log" && grep -q 'alpine:3$' "$work/log"; then echo "ok: stages, scratch and flags are no base images"; else echo "FAILED: asked for $asked base images: $(grep '^skopeo' "$work/log")"; failed=1; fi

# A base named by a variable is not known: no label, and every run builds.
printf 'ARG BASE=docker.io/library/alpine:3\nFROM ${BASE}\n' > "$work/ctx/Dockerfile"
LATEST=$(latest "$bases" "$now") run schedule 7; expect "scheduled, a base named by a variable" true
if grep -q 'digital.hueske.workflows.bases' "$work/log"; then echo "FAILED: a label for an unknown base"; failed=1; else echo "ok: no label for an unknown base"; fi

exit "$failed"
