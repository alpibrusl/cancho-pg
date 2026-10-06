#!/bin/sh
# Test certificates for the TLS tests (docs/tls.md section 7), written into the directory given (default build/tls):
#
#   ca.crt, ca.key          a test certificate authority (ECDSA P-256), the trust store the client is given
#   server.crt, server.key  the server's, issued by it, for the names localhost and pg.test and the address 127.0.0.1
#   other.crt               a second authority that issued nothing the server has: a trust store that must refuse it
#
# Made afresh on every run (nothing secret is kept: they live for two days and only a test trusts them). Needs OpenSSL 1.1.1 or
# later. Prints the directory.
set -eu
DIR=${1:-build/tls}
mkdir -p "$DIR"
cd "$DIR"

cat > ca.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ca
[dn]
CN = lexsys-pg test CA
[ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

cat > other.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ca
[dn]
CN = lexsys-pg other CA
[ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

cat > server.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = pg.test
[leaf]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, DNS:pg.test, IP:127.0.0.1
authorityKeyIdentifier = keyid
subjectKeyIdentifier = hash
EOF

openssl ecparam -name prime256v1 -genkey -noout -out ca.key 2>/dev/null
openssl req -new -x509 -key ca.key -sha256 -days 2 -config ca.cnf -out ca.crt
openssl ecparam -name prime256v1 -genkey -noout -out other.key 2>/dev/null
openssl req -new -x509 -key other.key -sha256 -days 2 -config other.cnf -out other.crt
openssl ecparam -name prime256v1 -genkey -noout -out server.key 2>/dev/null
openssl req -new -key server.key -sha256 -config server.cnf -out server.csr
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 -days 2 -extfile server.cnf -extensions leaf \
    -out server.crt 2>/dev/null
chmod 600 server.key ca.key other.key
pwd
