#!/usr/bin/env python3
"""Write a deterministic Flux OCI artifact layout tar for components/hello-world.

The layer holds manifests.yaml as a reproducible gzip tar, so Flux's
OCIRepository can fetch it and a Kustomization can patch its placeholders.

Usage: flux-artifact.py <output-dir>
"""
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFESTS = os.path.join(HERE, "manifests.yaml")
OUTPUT = "hello-world-kustomize.oci.tar"

IMAGE_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
IMAGE_INDEX = "application/vnd.oci.image.index.v1+json"
FLUX_CONFIG = "application/vnd.cncf.flux.config.v1+json"
FLUX_CONTENT = "application/vnd.cncf.flux.content.v1.tar+gzip"
REF_ANNOTATION = "org.opencontainers.image.ref.name"
REF_NAME = "latest"


def canon(obj):
    return json.dumps(obj, separators=(",", ":"), sort_keys=True).encode()


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def tar_bytes(files):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data in sorted(files):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mtime = 0
            info.mode = 0o644
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def gzip_bytes(data):
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(data)
    return buf.getvalue()


def add_blob(blobs, data, media_type):
    blobs[digest(data)] = data
    return {"mediaType": media_type, "digest": digest(data), "size": len(data)}


def artifact(blobs):
    with open(MANIFESTS, "rb") as f:
        manifests = f.read()
    layer = gzip_bytes(tar_bytes([("manifests.yaml", manifests)]))
    layer_desc = add_blob(blobs, layer, FLUX_CONTENT)
    config_desc = add_blob(blobs, canon({}), FLUX_CONFIG)
    manifest = canon({
        "schemaVersion": 2,
        "mediaType": IMAGE_MANIFEST,
        "config": config_desc,
        "layers": [layer_desc],
    })
    desc = add_blob(blobs, manifest, IMAGE_MANIFEST)
    desc["annotations"] = {REF_ANNOTATION: REF_NAME}
    return desc


def layout_tar(manifests, blobs):
    files = [
        ("oci-layout", canon({"imageLayoutVersion": "1.0.0"})),
        ("index.json", canon({"schemaVersion": 2, "mediaType": IMAGE_INDEX, "manifests": manifests})),
    ]
    files += [("blobs/sha256/" + d.split(":", 1)[1], data) for d, data in blobs.items()]
    return tar_bytes(files)


def main():
    if len(sys.argv) != 2:
        print("usage: flux-artifact.py <output-dir>", file=sys.stderr)
        sys.exit(2)
    blobs = {}
    desc = artifact(blobs)
    with open(os.path.join(sys.argv[1], OUTPUT), "wb") as f:
        f.write(layout_tar([desc], blobs))


if __name__ == "__main__":
    main()
