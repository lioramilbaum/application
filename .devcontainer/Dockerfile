FROM mcr.microsoft.com/devcontainers/base:3.0.12-ubuntu24.04
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends make shellcheck jq curl openssl ca-certificates python3 python3-yaml \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Renovate bumps OCM_CLI_VERSION and both OCM_SHA256_* ARGs in one PR (see
# renovate.json). Each "# renovate: ocm-linux-<arch> <version>" marker must sit
# directly above its ARG and equal OCM_CLI_VERSION. KIND_SHA256_* ARGs are still
# updated by hand.
ARG OCM_CLI_VERSION=v0.23.0
# renovate: ocm-linux-amd64 v0.23.0
ARG OCM_SHA256_LINUX_AMD64=b44c498d11fe102f1677ce097ed30039375b71e90f07450efeb14ce4b26d6ed5
# renovate: ocm-linux-arm64 v0.23.0
ARG OCM_SHA256_LINUX_ARM64=b8312c5a676968269d564ada71be4da1c2983ce11811c90ff94813495abf02bd
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

ARG FLUX_VERSION=v2.10.0
# Renovate bumps FLUX_VERSION (here and in scripts/controller.sh) and both
# FLUX_SHA256_* ARGs in one PR (see renovate.json). Each
# "# renovate: flux-linux-<arch> <version>" marker must sit directly above its
# ARG and equal FLUX_VERSION.
# renovate: flux-linux-amd64 v2.10.0
ARG FLUX_SHA256_LINUX_AMD64=208dd7012c04fedeed5b2d0b6e63df3b15b1c34a381527811685c098bc9f8659
# renovate: flux-linux-arm64 v2.10.0
ARG FLUX_SHA256_LINUX_ARM64=c3c435052e5e18156858bc73f26bcadb62821a6e30951b4b302beb4e65a532c2

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) sha="$FLUX_SHA256_LINUX_AMD64" ;; \
      arm64) sha="$FLUX_SHA256_LINUX_ARM64" ;; \
      *) echo "unsupported architecture: $arch"; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}/flux_${FLUX_VERSION#v}_linux_${arch}.tar.gz" \
      -o /tmp/flux.tar.gz; \
    echo "${sha}  /tmp/flux.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/flux.tar.gz -C /usr/local/bin flux; \
    rm /tmp/flux.tar.gz; \
    flux version --client
