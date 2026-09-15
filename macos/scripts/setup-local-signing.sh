#!/bin/bash
set -euo pipefail
umask 077

identity='Frog Local Code Signing'
keychain="$HOME/Library/Keychains/login.keychain-db"
[[ -f "$keychain" ]] || { echo '未找到当前用户的登录钥匙串。' >&2; exit 1; }
if /usr/bin/security find-identity -v -p codesigning "$keychain" | /usr/bin/grep -Fq "\"$identity\""; then
  echo "复用现有签名证书：$identity"
  exit 0
fi
if /usr/bin/security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
  echo "登录钥匙串已有同名证书，但不是有效签名身份。请检查有效期、代码签名信任及私钥，未创建替代证书。" >&2
  exit 1
fi

temporary="$(mktemp -d "${TMPDIR:-/tmp}/frog-signing.XXXXXX")"
trap 'rm -rf -- "$temporary"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$temporary/certificate.cnf" <<'CONFIG'
[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = Frog Local Code Signing
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
/usr/bin/openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
  -config "$temporary/certificate.cnf" -keyout "$temporary/private.pem" \
  -out "$temporary/certificate.pem" 2>"$temporary/generation.log"
# 临时目录仅当前用户可访问；直接导入密钥，避免在命令行传递钥匙串或传输密码。
/usr/bin/openssl rsa -in "$temporary/private.pem" -outform DER -out "$temporary/private.der" 2>/dev/null
/usr/bin/security import "$temporary/private.der" -f openssl -t priv -k "$keychain" -T /usr/bin/codesign
/usr/bin/security add-certificates -k "$keychain" "$temporary/certificate.pem"
rm -f -- "$temporary/private.pem" "$temporary/private.der"
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$temporary/certificate.pem"
if ! /usr/bin/security find-identity -v -p codesigning "$keychain" | /usr/bin/grep -Fq "\"$identity\""; then
  echo '证书已导入，但尚未成为有效签名身份；请在钥匙串访问中检查代码签名信任。' >&2
  exit 1
fi
echo "已配置固定本机签名：${identity}；私钥保存在登录钥匙串。"
