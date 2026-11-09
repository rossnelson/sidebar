# Sidebar

An Arc-style sidebar and frame for Google Chrome on macOS: tabs, bookmarks,
favorites per Chrome profile, and a Cmd+T palette.

## Build and run

```sh
Scripts/test.sh     # unit tests (works with only the Command Line Tools)
Scripts/bundle.sh   # builds build/Sidebar.app
open build/Sidebar.app
```

The app needs two permissions: **Accessibility** (to follow and resize Chrome's
window) and **Automation → Google Chrome** (to read and switch tabs).

## Stable signing

macOS ties the Accessibility permission to the code signature. With an ad-hoc
signature, every rebuild needs the permission again. `bundle.sh` signs with a
certificate named **Sidebar Local Signing** when one is in the keychain. To
create one:

```sh
cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Sidebar Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config cert.cnf -keyout key.pem -out cert.pem
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Sidebar Local Signing" -out id.p12 -passout pass:sidebar
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P sidebar -T /usr/bin/codesign
rm key.pem id.p12 cert.cnf
```

The certificate shows as "not trusted"; that is expected and does not matter
for local signing.
