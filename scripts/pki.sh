#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM" jq openssl

PKI_COMPONENT="github.com/lioramilbaum/pki-demo"
PKI_SIGNATURE="pki"
PKI_DEMO_CTF="${PKI_DEMO_CTF:-$BUILD_DIR/pki-ctf}"
PKI_DEMO_OUT="${PKI_DEMO_OUT:-$BUILD_DIR/pki}"
PKI_DEMO_CONSTRUCTOR="$ROOT/components/pki/component-constructor.yaml"
CERTS="$PKI_DEMO_OUT/certs"

# Bring your own PKI: set all three or none.
_byo=0
for _v in PKI_LEAF_KEY PKI_CHAIN PKI_ROOT_CERT; do
  [[ -z "${!_v:-}" ]] || _byo=$((_byo + 1))
done
(( _byo == 0 || _byo == 3 )) || die "set all of PKI_LEAF_KEY, PKI_CHAIN and PKI_ROOT_CERT, or none"
LEAF_KEY="${PKI_LEAF_KEY:-$CERTS/leaf.key}"
CHAIN="${PKI_CHAIN:-$CERTS/chain.pem}"
ROOT_CERT="${PKI_ROOT_CERT:-$CERTS/root.crt}"

_pki_ref() {
  echo "ctf::${1:-$PKI_DEMO_CTF}//${PKI_COMPONENT}:${VERSION}"
}

# _write_sign_config <private-key> <chain> <outfile>
_write_sign_config() {
  cat > "$3" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          algorithm: RSASSA-PSS
          signature: ${PKI_SIGNATURE}
        credentials:
          - type: RSACredentials/v1
            privateKeyPEMFile: $1
            publicKeyPEMFile: $2
  - type: signing.config.ocm.software/v1alpha1
    signer:
      type: RSASigningConfiguration/v1alpha1
      signatureAlgorithm: RSASSA-PSS
      signatureEncodingPolicy: PEM
EOF
}

# _write_verify_config <trust-file> <outfile>
_write_verify_config() {
  cat > "$2" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          algorithm: RSASSA-PSS
          signature: ${PKI_SIGNATURE}
        credentials:
          - type: RSACredentials/v1
            publicKeyPEMFile: $1
EOF
}

_ca_config() {
  mkdir -p "$CERTS/ca-db"
  : > "$CERTS/ca-db/index.txt"
  echo 1000 > "$CERTS/ca-db/serial"
  cat > "$CERTS/ca.cnf" <<EOF
[ req ]
distinguished_name = req_dn
[ req_dn ]
[ ca ]
default_ca = demo_ca
[ demo_ca ]
dir = $CERTS/ca-db
database = \$dir/index.txt
serial = \$dir/serial
new_certs_dir = \$dir
default_md = sha256
policy = cn_only
unique_subject = no
copy_extensions = none
[ cn_only ]
commonName = supplied
[ root_ext ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[ intermediate_ext ]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
[ codesign_ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
[ server_ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
EOF
}

# _key <name>
_key() {
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$CERTS/$1.key" 2>/dev/null
  chmod 0600 "$CERTS/$1.key"
}

# _self_signed <name> <cn>
_self_signed() {
  _key "$1"
  openssl req -x509 -new -key "$CERTS/$1.key" -subj "/CN=$2" -days 3650 \
    -config "$CERTS/ca.cnf" -extensions root_ext -out "$CERTS/$1.crt" 2>/dev/null
}

# _issue <name> <cn> <issuer> <extensions> <validity flags...>
_issue() {
  local name="$1" cn="$2" issuer="$3" ext="$4"
  shift 4
  _key "$name"
  openssl req -new -key "$CERTS/$name.key" -subj "/CN=$cn" -out "$CERTS/$name.csr" 2>/dev/null
  openssl ca -batch -notext -config "$CERTS/ca.cnf" \
    -cert "$CERTS/$issuer.crt" -keyfile "$CERTS/$issuer.key" \
    -extensions "$ext" "$@" \
    -in "$CERTS/$name.csr" -out "$CERTS/$name.crt" 2>/dev/null
}

_certs() {
  if [[ ! -f "$CERTS/root.crt" || ! -f "$CERTS/intermediate.key" ]]; then
    rm -rf "${CERTS:?}"
    mkdir -p "$CERTS"
    _ca_config
    _self_signed root "OCM Demo Root CA"
    _issue intermediate "OCM Demo Intermediate CA" root intermediate_ext -days 1825
  fi
  # A leaf that is missing or expires within a day is reissued under the same intermediate.
  if [[ ! -f "$CERTS/leaf.crt" ]] || ! openssl x509 -checkend 86400 -noout -in "$CERTS/leaf.crt" >/dev/null 2>&1; then
    _issue leaf "OCM Demo Signer" intermediate codesign_ext -days 30
  fi
  cat "$CERTS/leaf.crt" "$CERTS/intermediate.crt" > "$CERTS/chain.pem"
}

_configs() {
  _write_sign_config "$LEAF_KEY" "$CHAIN" "$PKI_DEMO_OUT/sign.ocmconfig"
  _write_verify_config "$ROOT_CERT" "$PKI_DEMO_OUT/verify.ocmconfig"
}

# _build_into <ctf>
_build_into() {
  "$OCM" add cv \
    --repository "ctf::$1" \
    --constructor "$PKI_DEMO_CONSTRUCTOR" \
    --config "$PKI_DEMO_OUT/verify.ocmconfig" < /dev/null >/dev/null
}

_build() {
  rm -rf "${PKI_DEMO_CTF:?}"
  _build_into "$PKI_DEMO_CTF"
}

# _sign_with <config> <ctf>
_sign_with() {
  "$OCM" sign cv --config "$1" --signature "$PKI_SIGNATURE" \
    "$(_pki_ref "$2")" < /dev/null >/dev/null
}

# _verify_with <config> <ctf>
_verify_with() {
  "$OCM" verify cv --config "$1" --signature "$PKI_SIGNATURE" \
    "$(_pki_ref "$2")" < /dev/null
}

_sign() {
  _sign_with "$PKI_DEMO_OUT/sign.ocmconfig" "$PKI_DEMO_CTF"
}

_verify() {
  _verify_with "${VERIFY_CONFIG:-$PKI_DEMO_OUT/verify.ocmconfig}" "$PKI_DEMO_CTF"
}

# _classify <stderr-file>
_classify() {
  local text
  text="$(cat "$1" 2>/dev/null || true)"
  # OCM 0.19.1
  if grep -q 'certificate has expired or is not yet valid' <<<"$text"; then
    echo expired
  # OCM 0.19.1
  elif grep -q 'incompatible key usage' <<<"$text"; then
    echo key-usage
  # OCM 0.19.1
  elif grep -q 'must not be embedded in the signature' <<<"$text"; then
    echo root-embedded
  # OCM 0.19.1
  elif grep -q 'unexpected pem block type for certificate' <<<"$text"; then
    echo not-a-certificate
  # OCM 0.19.1 — Go on Linux: "signed by unknown authority"; macOS platform verifier: "is not trusted"
  elif grep -qE 'certificate signed by unknown authority|certificate is not trusted' <<<"$text"; then
    echo unknown-authority
  # OCM 0.19.1
  elif grep -q 'digest mismatch' <<<"$text"; then
    echo digest-mismatch
  else
    echo error
  fi
}

_scenario_certs() {
  _issue leaf2 "OCM Demo Signer (rotated)" intermediate codesign_ext -days 30
  _issue expired "OCM Demo Signer (expired)" intermediate codesign_ext \
    -startdate 20200101000000Z -enddate 20200102000000Z
  _issue server "tls.example.com" intermediate server_ext -days 30
  _self_signed rogue-root "OCM Demo Root CA"
  cat "$CERTS/leaf2.crt" "$CERTS/intermediate.crt" > "$CERTS/chain-rotated.pem"
  cat "$CERTS/expired.crt" "$CERTS/intermediate.crt" > "$CERTS/chain-expired.pem"
  cat "$CERTS/server.crt" "$CERTS/intermediate.crt" > "$CERTS/chain-server.pem"
  cat "$CERTS/leaf.crt" "$CERTS/intermediate.crt" "$CERTS/root.crt" > "$CERTS/chain-with-root.pem"
  cat "$CERTS/intermediate.crt" "$CERTS/root.crt" > "$CERTS/intermediate-and-root.pem"
  openssl x509 -in "$CERTS/leaf.crt" -pubkey -noout > "$CERTS/leaf.pub"
}

_scenarios() {
  [[ -z "${PKI_ROOT_CERT:-}" ]] || die "scenarios use the generated demo PKI; unset PKI_LEAF_KEY, PKI_CHAIN and PKI_ROOT_CERT"
  _scenario_certs
  local dir="$PKI_DEMO_OUT/scenarios"
  rm -rf "${dir:?}"
  mkdir -p "$dir"
  _build_into "$dir/base-ctf"

  # <scenario> <signing key> <chain given to the signer> <file given to the verifier>
  local rows=(
    "valid leaf chain.pem root.crt"
    "rotated-leaf leaf2 chain-rotated.pem root.crt"
    "leaf-only-chain leaf leaf.crt root.crt"
    "verifier-supplies-intermediate leaf leaf.crt intermediate-and-root.pem"
    "rogue-root leaf chain.pem rogue-root.crt"
    "expired-leaf expired chain-expired.pem root.crt"
    "server-auth-leaf server chain-server.pem root.crt"
    "root-in-chain leaf chain-with-root.pem root.crt"
    "pinned-public-key leaf chain.pem leaf.pub"
    "intermediate-as-anchor leaf chain.pem intermediate.crt"
  )
  local row name key chain trust ctf sign_state verify_state reason
  for row in "${rows[@]}"; do
    read -r name key chain trust <<<"$row"
    ctf="$dir/$name-ctf"
    cp -R "$dir/base-ctf" "$ctf"
    _write_sign_config "$CERTS/$key.key" "$CERTS/$chain" "$dir/$name-sign.ocmconfig"
    _write_verify_config "$CERTS/$trust" "$dir/$name-verify.ocmconfig"
    sign_state=ok verify_state=ok reason=-
    if ! _sign_with "$dir/$name-sign.ocmconfig" "$ctf" 2>"$dir/$name.sign.stderr"; then
      sign_state=fail verify_state=- reason="$(_classify "$dir/$name.sign.stderr")"
    elif ! _verify_with "$dir/$name-verify.ocmconfig" "$ctf" >/dev/null 2>"$dir/$name.verify.stderr"; then
      verify_state=fail reason="$(_classify "$dir/$name.verify.stderr")"
    fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$sign_state" "$verify_state" "$reason"
  done
}

_show() {
  local sig_json value split i=0 cert
  sig_json="$("$OCM" get cv "$(_pki_ref)" -o json --config "$PKI_DEMO_OUT/verify.ocmconfig" < /dev/null \
    | jq -c --arg s "$PKI_SIGNATURE" '.[0].signatures[]? | select(.name==$s)')"
  [[ -n "$sig_json" ]] || die "no '$PKI_SIGNATURE' signature on $(_pki_ref) (run scripts/pki.sh sign first)"
  jq -r '["signature", .name, .signature.algorithm, .signature.mediaType] | @tsv' <<<"$sig_json"
  jq -r '["digest", .digest.normalisationAlgorithm, .digest.hashAlgorithm, .digest.value] | @tsv' <<<"$sig_json"
  value="$(jq -r '.signature.value' <<<"$sig_json")"
  split="$PKI_DEMO_OUT/embedded-chain"
  rm -rf "${split:?}"
  mkdir -p "$split"
  awk -v d="$split" '/-----BEGIN CERTIFICATE-----/{n++; f=1} f{print > (d "/" n ".pem")} /-----END CERTIFICATE-----/{f=0}' <<<"$value"
  for cert in "$split"/*.pem; do
    [[ -f "$cert" ]] || continue
    printf 'cert\t%s\t%s\t%s\n' "$i" \
      "$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 | sed 's/^subject= *//')" \
      "$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 | sed 's/^issuer= *//')"
    i=$((i + 1))
  done
}

mkdir -p "$PKI_DEMO_OUT"
[[ -n "${PKI_ROOT_CERT:-}" ]] || _certs
_configs

case "${1:-}" in
  certs)     ;;
  build)     _build ;;
  sign)      _sign ;;
  verify)    _verify ;;
  scenarios) _scenarios ;;
  show)      _show ;;
  *)         _build; _sign; _verify; echo ""; _show ;;
esac
