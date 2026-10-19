#!/usr/bin/env python3
"""Write deterministic OCI image layout tars for components/oci.

Usage: layout.py <output-dir>
"""
import hashlib
import io
import json
import os
import sys
import tarfile

IMAGE_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
IMAGE_INDEX = "application/vnd.oci.image.index.v1+json"
IMAGE_CONFIG = "application/vnd.oci.image.config.v1+json"
LAYER = "application/vnd.oci.image.layer.v1.tar"
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


def add_blob(blobs, data, media_type):
    blobs[digest(data)] = data
    return {"mediaType": media_type, "digest": digest(data), "size": len(data)}


def image(arch, blobs):
    layer = tar_bytes([("hello.txt", f"hello from {arch}\n".encode())])
    layer_desc = add_blob(blobs, layer, LAYER)
    config = canon({
        "architecture": arch,
        "os": "linux",
        "rootfs": {"type": "layers", "diff_ids": [digest(layer)]},
        "config": {},
    })
    config_desc = add_blob(blobs, config, IMAGE_CONFIG)
    manifest = canon({
        "schemaVersion": 2,
        "mediaType": IMAGE_MANIFEST,
        "config": config_desc,
        "layers": [layer_desc],
    })
    return add_blob(blobs, manifest, IMAGE_MANIFEST)


def layout_tar(manifests, blobs):
    files = [
        ("oci-layout", canon({"imageLayoutVersion": "1.0.0"})),
        ("index.json", canon({"schemaVersion": 2, "mediaType": IMAGE_INDEX, "manifests": manifests})),
    ]
    files += [("blobs/sha256/" + d.split(":", 1)[1], data) for d, data in blobs.items()]
    return tar_bytes(files)


def single(arch):
    blobs = {}
    desc = image(arch, blobs)
    desc["annotations"] = {REF_ANNOTATION: REF_NAME}
    return layout_tar([desc], blobs)


def multiarch():
    blobs = {}
    variants = []
    for arch in ("amd64", "arm64"):
        desc = image(arch, blobs)
        desc["platform"] = {"architecture": arch, "os": "linux"}
        variants.append(desc)
    index_desc = add_blob(blobs, canon({"schemaVersion": 2, "mediaType": IMAGE_INDEX, "manifests": variants}), IMAGE_INDEX)
    index_desc["annotations"] = {REF_ANNOTATION: REF_NAME}
    return layout_tar([index_desc], blobs)


def main():
    if len(sys.argv) != 2:
        print("usage: layout.py <output-dir>", file=sys.stderr)
        sys.exit(2)
    outdir = sys.argv[1]
    outputs = {
        "hello-oci-amd64.oci.tar": single("amd64"),
        "hello-oci-arm64.oci.tar": single("arm64"),
        "hello-oci-multiarch.oci.tar": multiarch(),
    }
    for name, data in outputs.items():
        with open(os.path.join(outdir, name), "wb") as f:
            f.write(data)


if __name__ == "__main__":
    main()
