#!/usr/bin/env bash
# ================================================================
#  Versao macOS/Linux do ataques.ps1 (mesmos testes, mesmo corpo).
#
#  Uso (na pasta scripts):
#    ./ataques.sh -u https://sua-api.SEU-USUARIO.workers.dev -t Falso
#    ./ataques.sh -u URL -k SUA_API_KEY -t Todos
#    ./ataques.sh -u URL -k SUA_API_KEY -m SUA_CHAVE_HMAC -t Todos
#
#  Atalho: sem -k / -m, as chaves sao lidas do esp32/estacao_cofre/config.h
#  (assim elas nao aparecem no historico do terminal nem no print).
#  Use -c para NAO ler o config.h (ex.: Passo 1, sem chave nenhuma).
#
#  Testes: Falso SemChave ComChave Valido Adulterado Replay Atrasado Tentativas Todos
# ================================================================
set -u
URL=""; API_KEY=""; CHAVE_HMAC=""; TESTE="Todos"; LER_CONFIG=1
while getopts "u:k:m:t:c" o; do
  case $o in
    u) URL="${OPTARG%/}" ;; k) API_KEY="$OPTARG" ;; m) CHAVE_HMAC="$OPTARG" ;;
    t) TESTE="$OPTARG" ;; c) LER_CONFIG=0 ;;
    *) echo "uso: $0 -u URL [-k API_KEY] [-m CHAVE_HMAC] [-t Teste] [-c]"; exit 1 ;;
  esac
done
[ -z "$URL" ] && { echo "Passe -u URL do Worker"; exit 1; }

CFG="$(cd "$(dirname "$0")" && pwd)/../esp32/estacao_cofre/config.h"
ler() { sed -nE "s/^#define $1 +\"([^\"]*)\".*/\1/p" "$CFG"; }
if [ "$LER_CONFIG" = 1 ] && [ -f "$CFG" ]; then
  [ -z "$API_KEY" ] && API_KEY="$(ler API_KEY)"
  # A chave HMAC so entra se voce pedir os testes de assinatura (-m auto)
  [ "$CHAVE_HMAC" = "auto" ] && CHAVE_HMAC="$(ler CHAVE_HMAC)"
fi

C='\033[36m'; Y='\033[33m'; G='\033[32m'; R='\033[31m'; N='\033[0m'
agora() { date -u +%s; }
corpo() { printf '{"nome":"atacante","sensor":"temp","valor":%s,"ts":%s}' "$1" "$2"; }
assinar() {
  [ -z "$CHAVE_HMAC" ] && { echo "Passe -m CHAVE_HMAC (ou -m auto)" >&2; exit 1; }
  printf '%s' "$1" | openssl dgst -sha256 -hmac "$CHAVE_HMAC" | awk '{print $NF}'
}
# enviar CORPO [API_KEY] [ASSINATURA]  -> imprime "STATUS<TAB>TEXTO"
enviar() {
  local args=(-s -o /tmp/.ataque_resp.$$ -w '%{http_code}' -X POST "$URL/insert"
              -H "Content-Type: application/json" --data-binary "$1")
  [ -n "${2:-}" ] && args+=(-H "X-API-Key: $2")
  [ -n "${3:-}" ] && args+=(-H "X-Assinatura: $3")
  local st; st=$(curl "${args[@]}")
  printf '%s\t%s' "$st" "$(cat /tmp/.ataque_resp.$$ 2>/dev/null)"; rm -f /tmp/.ataque_resp.$$
}
mostrar() {  # nome esperado "status<TAB>texto"
  local st="${3%%$'\t'*}" tx="${3#*$'\t'}" cor="$G"
  [[ "$st" =~ ^2 ]] && cor="$Y"
  printf "\n${C}== %s ==${N}\n   esperado (camada 3 ligada): %s\n${cor}   obtido: HTTP %s  %s${N}\n" "$1" "$2" "$st" "$tx"
}

Teste_Falso()    { mostrar "Falso (sem nada)" "401 - antes das camadas, isto GRAVAVA 999 no seu banco" "$(enviar "$(corpo 999 "$(agora)")")"; }
Teste_SemChave() { mostrar "Sem API key" "401" "$(enviar "$(corpo 25.0 "$(agora)")")"; }
Teste_ComChave() { mostrar "Com API key, sem assinatura" "401 (na camada 2 ainda passa: 200)" "$(enviar "$(corpo 25.0 "$(agora)")" "$API_KEY")"; }
Teste_Valido()   { local c; c=$(corpo 25.0 "$(agora)"); mostrar "Valido (API key + assinatura)" "200" "$(enviar "$c" "$API_KEY" "$(assinar "$c")")"; }
Teste_Adulterado() {
  local ts; ts=$(agora)
  local sig; sig=$(assinar "$(corpo 25.0 "$ts")")   # assinou 25.0 ...
  mostrar "Adulterado (assina 25.0, manda 45.0)" "401 assinatura invalida" "$(enviar "$(corpo 45.0 "$ts")" "$API_KEY" "$sig")"
}
Teste_Replay() {
  local c; c=$(corpo 25.0 "$(agora)"); local sig; sig=$(assinar "$c")
  mostrar "Replay - 1a vez" "200" "$(enviar "$c" "$API_KEY" "$sig")"
  mostrar "Replay - 2a vez (mesma requisicao)" "401 replay" "$(enviar "$c" "$API_KEY" "$sig")"
}
Teste_Atrasado() { local c; c=$(corpo 25.0 $(( $(agora) - 300 ))); mostrar "Atrasado (ts de 5 min atras)" "401 expirada" "$(enviar "$c" "$API_KEY" "$(assinar "$c")")"; }
Teste_Tentativas() {
  printf "\n${C}== Tentativas recusadas (GET /tentativas) ==${N}\n"
  local j; j=$(curl -s -H "X-API-Key: $API_KEY" "$URL/tentativas")
  if command -v python3 >/dev/null; then
    printf '%s' "$j" | python3 -c '
import sys, json, datetime
d = json.load(sys.stdin)
print("   %-55s %-40s %s" % ("motivo", "ip", "quando"))
for t in d[:10]:
    q = datetime.datetime.fromtimestamp(t["timestamp"]/1000).strftime("%H:%M:%S")
    print("   %-55s %-40s %s" % (t["motivo"], t["ip"], q))' 2>/dev/null || echo "   $j"
  else echo "   $j"; fi
}

case "$TESTE" in
  Todos)
    Teste_Falso; Teste_SemChave; Teste_ComChave
    if [ -n "$CHAVE_HMAC" ]; then Teste_Valido; Teste_Adulterado; Teste_Replay; Teste_Atrasado
    else printf "\n(sem -m: pulei os testes de assinatura)\n"; fi
    [ -n "$API_KEY" ] && Teste_Tentativas ;;
  Falso|SemChave|ComChave|Valido|Adulterado|Replay|Atrasado|Tentativas) "Teste_$TESTE" ;;
  *) echo "Teste desconhecido: $TESTE"; exit 1 ;;
esac
echo
