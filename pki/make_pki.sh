#!/bin/bash
# Idempotent local PKI: CA (stays on kali) + server cert for odoo.pca.lab (SAN DNS + IP of lb01).
set -euo pipefail
cd "$(dirname "$0")"
umask 077
if [ ! -f ca.key ]; then
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days 825 -subj "/C=TN/O=PCA Lab/CN=PCA Lab Root CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.crt
fi
if [ ! -f odoo.pca.lab.crt ] || ! openssl x509 -checkend 2592000 -noout -in odoo.pca.lab.crt; then
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out odoo.pca.lab.key
  openssl req -new -key odoo.pca.lab.key -subj "/C=TN/O=PCA Lab/CN=odoo.pca.lab" -out odoo.pca.lab.csr
  cat > server.ext <<X
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:odoo.pca.lab,DNS:lb01.pca.lab,IP:192.168.100.20
X
  openssl x509 -req -in odoo.pca.lab.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 397 -sha256 -extfile server.ext -out odoo.pca.lab.crt
  rm -f odoo.pca.lab.csr
fi
cat odoo.pca.lab.crt ca.crt odoo.pca.lab.key > odoo.pca.lab.pem   # HAProxy bundle: cert + chain + key
chmod 600 *.key *.pem; chmod 644 ca.crt odoo.pca.lab.crt
openssl verify -CAfile ca.crt odoo.pca.lab.crt
openssl x509 -in odoo.pca.lab.crt -noout -subject -ext subjectAltName -enddate
