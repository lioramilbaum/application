FROM mcr.microsoft.com/devcontainers/base:3.0.8-ubuntu24.04
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends make shellcheck jq curl openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Renovate bumps OCM_CLI_VERSION and both OCM_SHA256_* ARGs in one PR (see
# renovate.json). Each "# renovate: ocm-linux-<arch> <version>" marker must sit
# directly above its ARG and equal OCM_CLI_VERSION. KIND_SHA256_* ARGs are still
# updated by hand.
ARG OCM_CLI_VERSION=v0.19.0
# renovate: ocm-linux-amd64 v0.19.0
ARG OCM_SHA256_LINUX_AMD64=94130f700a92853b180f8677881a4bfa173782ee3914c38294be2d3d51fa5cbe
# renovate: ocm-linux-arm64 v0.19.0
ARG OCM_SHA256_LINUX_ARM64=411d5fcaf8d1d2c698f59f953cdf3b035d9efdca984b48096363f7e163bbae9b
ARG KIND_VERSION=v0.33.0
ARG KIND_SHA256_LINUX_AMD64=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
ARG KIND_SHA256_LINUX_ARM64=20022bee6cfcd5086cb7234d218e3454e6090022f2a8f55d1fa7fcf42c3867a2

RUN set -eux; arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) ocm_sha="$OCM_SHA256_LINUX_AMD64"; kind_sha="$KIND_SHA256_LINUX_AMD64" ;; \
      arm64) ocm_sha="$OCM_SHA256_LINUX_ARM64"; kind_sha="$KIND_SHA256_LINUX_ARM64" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/ocm  "https://github.com/open-component-model/open-component-model/releases/download/${OCM_CLI_VERSION}/ocm-linux-${arch}"; \
    curl -fsSL -o /tmp/kind "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${arch}"; \
    echo "${ocm_sha}  /tmp/ocm"   | sha256sum -c -; \
    echo "${kind_sha}  /tmp/kind" | sha256sum -c -; \
    install -m 0755 /tmp/ocm /usr/local/bin/ocm; \
    install -m 0755 /tmp/kind /usr/local/bin/kind; \
    rm -f /tmp/ocm /tmp/kind; \
    ocm version; \
    kind version
