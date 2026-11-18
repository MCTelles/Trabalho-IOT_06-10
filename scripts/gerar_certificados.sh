#!/usr/bin/env bash
# ================================================================
#  Versao macOS do gerar_certificados.ps1 -> esp32/estacao_cofre/certificados.h
#
#  Uso (na pasta scripts):
#    ./gerar_certificados.sh sua-api.SEU-USUARIO.workers.dev
#
#  1. Pega a cadeia que o seu Worker apresenta (sem o leaf do site)
#     e acrescenta a CA raiz correspondente, tirada das raizes do macOS.
#  2. Baixa a CA do test.mosquitto.org.
#  3. Escreve o certificados.h (so certificados PUBLICOS: pode versionar).
# ================================================================
set -euo pipefail
# O openssl do macOS (LibreSSL) nao fecha o handshake com a Cloudflare:
# usa o do Homebrew se existir (brew install openssl).
for o in /opt/homebrew/bin/openssl /usr/local/bin/openssl; do
  [ -x "$o" ] && { openssl() { "$o" "$@"; }; break; }
done
[ $# -lt 1 ] && { echo "uso: $0 sua-api.SEU-USUARIO.workers.dev"; exit 1; }
HOST=$(echo "$1" | sed -E 's#^https?://##; s#/.*$##')
AQUI="$(cd "$(dirname "$0")" && pwd)"
DEST="$AQUI/../esp32/estacao_cofre/certificados.h"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "Conectando em $HOST ..."
openssl s_client -showcerts -connect "$HOST:443" -servername "$HOST" </dev/null 2>/dev/null |
  awk -v d="$TMP" '/BEGIN CERT/{n++; f=sprintf("%s/c%02d.pem", d, n)} f{print > f} /END CERT/{f=""}'
CERTS=("$TMP"/c*.pem)
[ ${#CERTS[@]} -lt 1 ] || [ ! -s "${CERTS[0]}" ] && { echo "Nao consegui pegar a cadeia do Worker."; exit 1; }
echo "Certificado do site: $(openssl x509 -in "${CERTS[0]}" -noout -subject)"

PEM_WORKER=""
for ((i=1; i<${#CERTS[@]}; i++)); do               # i=0 e' o leaf: pula
  c="${CERTS[$i]}"
  echo "  + CA: $(openssl x509 -in "$c" -noout -subject)  (ate $(openssl x509 -in "$c" -noout -enddate | cut -d= -f2))"
  PEM_WORKER+="$(cat "$c")"$'\n'
done

# Raiz: procura nas raizes do sistema a que emitiu o ultimo certificado da cadeia
ULTIMO="${CERTS[${#CERTS[@]}-1]}"
ISSUER_HASH=$(openssl x509 -in "$ULTIMO" -noout -issuer_hash)
SUBJ_HASH=$(openssl x509 -in "$ULTIMO" -noout -subject_hash)
if [ "$ISSUER_HASH" != "$SUBJ_HASH" ]; then
  security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain |
    awk -v d="$TMP" '/BEGIN CERT/{n++; f=sprintf("%s/r%03d.pem", d, n)} f{print > f} /END CERT/{f=""}'
  for r in "$TMP"/r*.pem; do
    if [ "$(openssl x509 -in "$r" -noout -subject_hash 2>/dev/null)" = "$ISSUER_HASH" ] &&
       openssl verify -partial_chain -CAfile "$r" "$ULTIMO" >/dev/null 2>&1; then
      echo "  + CA raiz: $(openssl x509 -in "$r" -noout -subject)"
      PEM_WORKER+="$(cat "$r")"$'\n'
      break
    fi
  done
fi
[ -z "$PEM_WORKER" ] && { echo "Nao consegui montar a cadeia do Worker."; exit 1; }

echo "Baixando a CA do test.mosquitto.org ..."
MOSQ=$(curl -fsSL https://test.mosquitto.org/ssl/mosquitto.org.crt | tr -d '\r')
echo "$MOSQ" | grep -q "BEGIN CERTIFICATE" || { echo "O arquivo baixado nao parece um certificado PEM."; exit 1; }
echo "  + CA: mosquitto.org"

cat > "$DEST" <<EOF
// Gerado por gerar_certificados.sh em $(date '+%d/%m/%Y %H:%M') para $HOST
// Certificados PUBLICOS das autoridades (CAs): pode versionar, nao e' segredo.

const char* CA_WORKER = R"CERT(
${PEM_WORKER%$'\n'}
)CERT";

const char* CA_MOSQUITTO = R"CERT(
$MOSQ
)CERT";
EOF
echo; echo "Pronto: $(cd "$(dirname "$DEST")" && pwd)/certificados.h"
