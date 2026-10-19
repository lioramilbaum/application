#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM" jq curl

S3_COMPONENT="github.com/lioramilbaum/s3-demo"
S3_NAME="${S3_NAME:-ocm-demo-s3}"
S3_IMAGE="${S3_IMAGE:-rustfs/rustfs:1.0.0-rc.6@sha256:97171b3d72cd47dc81000f92ea84de25608bfc35a94c965501afaeb5d99f6035}"
S3_HOST="${S3_HOST:-127.0.0.1}"
S3_PORT="${S3_PORT:-19000}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-ocm-demo}"
S3_SECRET_KEY="${S3_SECRET_KEY:-ocm-demo-secret}"
S3_DEMO_CTF="${S3_DEMO_CTF:-$BUILD_DIR/s3-ctf}"
S3_DEMO_OUT="${S3_DEMO_OUT:-$BUILD_DIR/s3}"
S3_DEMO_ENDPOINT="http://${S3_HOST}:${S3_PORT}"
S3_OCMCONFIG="${S3_DEMO_OUT}/s3.ocmconfig"

# Isolate from developer AWS credentials.
export AWS_SHARED_CREDENTIALS_FILE=/dev/null
export AWS_CONFIG_FILE=/dev/null
export AWS_EC2_METADATA_DISABLED=true
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE 2>/dev/null || true

_docker_available() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

_require_docker() {
  if ! _docker_available; then
    echo "skip: Docker is not available; the S3 resources demo needs a Docker daemon" >&2
    exit 0
  fi
}

_running() {
  docker inspect -f '{{.State.Running}}' "$S3_NAME" 2>/dev/null | grep -q true
}

_wait_ready() {
  local _
  for _ in $(seq 1 40); do
    if curl -fsS "${S3_DEMO_ENDPOINT}/health/ready" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  die "S3 server not reachable at ${S3_DEMO_ENDPOINT}/health/ready"
}

_start() {
  _require_docker
  if _running; then
    _wait_ready >/dev/null
    echo "$S3_DEMO_ENDPOINT"
    return
  fi
  docker rm -f "$S3_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$S3_NAME" \
    -p "${S3_HOST}:${S3_PORT}:9000" \
    -e RUSTFS_ACCESS_KEY="$S3_ACCESS_KEY" \
    -e RUSTFS_SECRET_KEY="$S3_SECRET_KEY" \
    "$S3_IMAGE" >/dev/null \
    || die "failed to start S3 server (is port ${S3_PORT} in use?)"
  _wait_ready >/dev/null
  echo "$S3_DEMO_ENDPOINT"
}

_stop() {
  _require_docker
  docker rm -f "$S3_NAME" >/dev/null 2>&1 || true
}

# _s3_curl <method> <path> [extra curl args...]
_s3_curl() {
  local method="$1" path="$2"; shift 2
  local url="${S3_DEMO_ENDPOINT}${path}"
  local sha256_empty="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  curl -fsS -X "$method" \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    --user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -H "x-amz-content-sha256: ${sha256_empty}" \
    "$@" "$url"
}

_seed() {
  mkdir -p "$S3_DEMO_OUT"
  local file="$ROOT/components/s3/upstream/release-notes.txt"
  local sha; sha="$(sha256 "$file")"

  # Create buckets.
  _s3_curl PUT /ocm-demo >/dev/null
  _s3_curl PUT /ocm-demo-versioned >/dev/null

  # Enable versioning on ocm-demo-versioned.
  # The body hash must match x-amz-content-sha256; the empty-body hash returns 500.
  local versioning='<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>'
  local versioning_sha; versioning_sha="$(printf '%s' "$versioning" | shasum -a 256 | awk '{print $1}')"
  curl -fsS -X PUT \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    --user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -H "Content-Type: application/xml" \
    -H "x-amz-content-sha256: ${versioning_sha}" \
    --data-raw "$versioning" \
    "${S3_DEMO_ENDPOINT}/ocm-demo-versioned?versioning" >/dev/null

  # Upload to both buckets.
  curl -fsS -X PUT \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    --user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -H "Content-Type: text/plain" \
    -H "x-amz-content-sha256: ${sha}" \
    --data-binary @"$file" \
    "${S3_DEMO_ENDPOINT}/ocm-demo/releases/notes.txt" >/dev/null

  curl -fsS -X PUT \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    --user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -H "Content-Type: text/plain" \
    -H "x-amz-content-sha256: ${sha}" \
    --data-binary @"$file" \
    "${S3_DEMO_ENDPOINT}/ocm-demo-versioned/releases/notes.txt" \
    -D - -o /dev/null 2>&1 \
    | grep -i 'x-amz-version-id' | awk '{print $2}' | tr -d '\r' \
    > "$S3_DEMO_OUT/seed-version"

  printf 'ocm-demo\t%s\n' "$sha"
  printf 'ocm-demo-versioned\t%s\t%s\n' "$sha" "$(cat "$S3_DEMO_OUT/seed-version" 2>/dev/null || echo '')"
}

_config() {
  mkdir -p "$S3_DEMO_OUT"
  cat > "$S3_OCMCONFIG" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software/v1
    consumers:
      - identity:
          type: S3
          scheme: http
          hostname: ${S3_HOST}
          port: "${S3_PORT}"
        credentials:
          - type: S3Credentials/v1
            accessKeyId: ${S3_ACCESS_KEY}
            secretAccessKey: ${S3_SECRET_KEY}
EOF
}

_component_ref() {
  echo "ctf::${S3_DEMO_CTF}//${S3_COMPONENT}:${VERSION}"
}

_build() {
  _config
  rm -rf "${S3_DEMO_CTF:?}"
  S3_DEMO_ENDPOINT="$S3_DEMO_ENDPOINT" \
    "$OCM" add cv --repository "ctf::$S3_DEMO_CTF" \
      --constructor "$ROOT/components/s3/component-constructor.yaml" \
      --config "$S3_OCMCONFIG" </dev/null
}

_sign() {
  "$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" --signature default \
    "$(_component_ref)" </dev/null >/dev/null
}

_verify() {
  "$OCM" verify cv --config "$BUILD_DIR/verify.ocmconfig" --signature default \
    "$(_component_ref)" </dev/null
}

_download() {
  _verify >/dev/null
  local stage; stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' RETURN
  local ok=1
  for name in notes-v1 notes notes-pinned notes-input; do
    local out="$stage/${name}"
    if "$OCM" download resource \
        --identity "name=${name}" \
        --output "$out" \
        --config "$S3_OCMCONFIG" \
        "$(_component_ref)" </dev/null >/dev/null; then
      local stored actual
      stored="$("$OCM" get cv "$(_component_ref)" -o json </dev/null \
        | jq -r --arg n "$name" '.[0].component.resources[] | select(.name==$n) | .digest.value')"
      actual="$(sha256 "$out")"
      if [[ "$stored" != "$actual" ]]; then
        printf 'download\t%s\tdigest-mismatch\t%s != %s\n' "$name" "$stored" "$actual"
        ok=0
      else
        printf 'download\t%s\tok\t%s\n' "$name" "$actual"
      fi
    else
      printf 'download\t%s\tfailed\n' "$name"
      ok=0
    fi
  done
  [[ "$ok" == "1" ]] || die "one or more downloads failed"
}

_overwrite() {
  local content="$1"
  local sha; sha="$(printf '%s' "$content" | shasum -a 256 | awk '{print $1}')"
  curl -fsS -X PUT \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    --user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -H "Content-Type: text/plain" \
    -H "x-amz-content-sha256: ${sha}" \
    --data-raw "$content" \
    "${S3_DEMO_ENDPOINT}/ocm-demo/releases/notes.txt" \
    -D - -o /dev/null 2>&1 | grep -i 'x-amz-version-id' | awk '{print $2}' | tr -d '\r' || true
}

_restore() {
  curl -fsS -X PUT \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    --user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -H "Content-Type: text/plain" \
    -H "x-amz-content-sha256: $(sha256 "$ROOT/components/s3/upstream/release-notes.txt")" \
    --data-binary @"$ROOT/components/s3/upstream/release-notes.txt" \
    "${S3_DEMO_ENDPOINT}/ocm-demo/releases/notes.txt" >/dev/null
}

# _classify_err <err-text>
_classify_err() {
  local err="$1"
  if echo "$err" | grep -q "digest mismatch"; then
    echo "digest-mismatch"
  elif echo "$err" | grep -q "get credentials\|failed to refresh"; then
    # OCM 0.19.1: no matching consumer → credential refresh fails
    echo "credentials-missing"
  elif echo "$err" | grep -q "connection refused\|dial"; then
    echo "connection-refused"
  else
    echo "error: $err"
  fi
}

_try_download() {
  local name="$1" config="$2"
  local stage; stage="$(mktemp -d)"
  local out="$stage/${name}"
  # OCM logs to stderr on success too, so the exit status decides, not the output.
  local err rc=0
  err="$("$OCM" download resource \
    --identity "name=${name}" \
    --output "$out" \
    --config "$config" \
    "$(_component_ref)" </dev/null 2>&1 >/dev/null)" || rc=$?
  rm -rf "$stage"
  if (( rc == 0 )); then
    echo "ok"
  else
    _classify_err "$err"
  fi
}

_scenarios() {
  local tmp_config; tmp_config="$(mktemp)"
  trap 'rm -f "$tmp_config"' RETURN

  printf 'scenario\tresource\tresult\n'

  # pinned: normal download
  printf 'pinned\tnotes\t%s\n' "$(_try_download notes "$S3_OCMCONFIG")"
  printf 'pinned\tnotes-v1\t%s\n' "$(_try_download notes-v1 "$S3_OCMCONFIG")"

  # overwritten: digest changes
  _overwrite "tampered content" >/dev/null
  printf 'overwritten\tnotes\t%s\n' "$(_try_download notes "$S3_OCMCONFIG")"
  printf 'overwritten\tnotes-v1\t%s\n' "$(_try_download notes-v1 "$S3_OCMCONFIG")"
  _restore

  # overwritten-versioned: version pin protects
  _overwrite "tampered content" >/dev/null  # only overwrites ocm-demo, not versioned
  # Also overwrite versioned bucket
  curl -fsS -X PUT \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    --user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -H "Content-Type: text/plain" \
    -H "x-amz-content-sha256: $(printf '%s' 'tampered versioned' | shasum -a 256 | awk '{print $1}')" \
    --data-raw "tampered versioned" \
    "${S3_DEMO_ENDPOINT}/ocm-demo-versioned/releases/notes.txt" >/dev/null || true
  printf 'overwritten-versioned\tnotes-pinned\t%s\n' "$(_try_download notes-pinned "$S3_OCMCONFIG")"
  _restore

  # input: LocalBlob, server not needed
  printf 'overwritten-input\tnotes-input\t%s\n' "$(_try_download notes-input "$S3_OCMCONFIG")"

  # no-credentials: empty config
  printf 'type: generic.config.ocm.software/v1\nconfigurations: []\n' > "$tmp_config"
  printf 'no-credentials\tnotes\t%s\n' "$(_try_download notes "$tmp_config")"

  # glob-star: the identity path is bucket/key, and path.Match's * stays within one segment
  cat > "$tmp_config" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software/v1
    consumers:
      - identity:
          type: S3
          scheme: http
          hostname: ${S3_HOST}
          port: "${S3_PORT}"
          path: "ocm-demo/releases/*"
        credentials:
          - type: S3Credentials/v1
            accessKeyId: ${S3_ACCESS_KEY}
            secretAccessKey: ${S3_SECRET_KEY}
EOF
  printf 'glob-star\tnotes\t%s\n' "$(_try_download notes "$tmp_config")"

  # glob-doublestar: ** not supported in 0.19.1
  cat > "$tmp_config" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software/v1
    consumers:
      - identity:
          type: S3
          scheme: http
          hostname: ${S3_HOST}
          port: "${S3_PORT}"
          path: "ocm-demo/**"
        credentials:
          - type: S3Credentials/v1
            accessKeyId: ${S3_ACCESS_KEY}
            secretAccessKey: ${S3_SECRET_KEY}
EOF
  printf 'glob-doublestar\tnotes\t%s\n' "$(_try_download notes "$tmp_config")"

  # copied-v2: S3/v2 → LocalBlob after --copy-resources (needs the server, so it runs before server-down)
  local copied_ctf="$S3_DEMO_OUT/copied-ctf"
  rm -rf "${copied_ctf:?}"
  "$OCM" transfer cv --copy-resources "$(_component_ref)" "ctf::$copied_ctf" \
    --config "$S3_OCMCONFIG" </dev/null >/dev/null
  local v2_type v1_type
  v2_type="$("$OCM" get cv "ctf::${copied_ctf}//${S3_COMPONENT}:${VERSION}" \
    -o json </dev/null | jq -r '.[0].component.resources[] | select(.name=="notes") | .access.type')"
  v1_type="$("$OCM" get cv "ctf::${copied_ctf}//${S3_COMPONENT}:${VERSION}" \
    -o json </dev/null | jq -r '.[0].component.resources[] | select(.name=="notes-v1") | .access.type')"
  printf 'copied-v2\tnotes\t%s\n' "$v2_type"
  printf 'copied-v1\tnotes-v1\t%s\n' "$v1_type"

  # server-down: access fails, input ok. Stopping the container drops its data, so the
  # server is seeded again after the restart.
  _stop >/dev/null 2>&1
  printf 'server-down\tnotes\t%s\n' "$(_try_download notes "$S3_OCMCONFIG")"
  printf 'server-down\tnotes-input\t%s\n' "$(_try_download notes-input "$S3_OCMCONFIG")"
  _start >/dev/null
  _seed >/dev/null
}

_show() {
  "$OCM" get cv "$(_component_ref)" -o json </dev/null | jq -r '
    .[0].component.resources[] |
    [.name, .relation, .access.type,
     (.access.version // .access.objectKey // .access.key // "-"),
     .digest.value] | @tsv'
}

mkdir -p "$S3_DEMO_OUT"

case "${1:-}" in
  start)     _start ;;
  stop)      _stop ;;
  seed)      _seed ;;
  config)    _config ;;
  build)     _build ;;
  sign)      _sign ;;
  verify)    _verify ;;
  download)  _download ;;
  scenarios) _scenarios ;;
  show)      _show ;;
  *)         _require_docker; _start >/dev/null; _seed >/dev/null; _build; echo ""; _sign; _verify; echo ""; _show; echo ""; _scenarios ;;
esac
