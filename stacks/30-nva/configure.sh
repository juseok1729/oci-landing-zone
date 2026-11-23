#!/usr/bin/env bash
# NVA(VyOS) 에 terraform output vyos_config 를 적용한다.  make configure-nva [NVA=<이름>]
#   SSH 는 비밀번호 인증이다: repo 루트 .env.local 의 NVA_PASS (.gitignore 에 있다)
set -euo pipefail
cd "$(dirname "$0")/../.."
nva="${1:-NVA}"

set -a; . ./.env.local; set +a
: "${NVA_PASS:?.env.local 에 NVA_PASS 가 없습니다}"

out() { terraform -chdir=stacks/30-nva output -json "$1" | jq -er --arg n "$nva" '.[$n]'; }
host=$(out nva_ssh_host)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
out vyos_config > "$tmp/vyos-config.sh"

# 비밀번호는 파일에 쓰지 않는다: ssh 가 SSH_ASKPASS 를 실행하면 환경변수 NVA_PASS 를 출력한다
cat > "$tmp/askpass" <<'ASKPASS'
#!/bin/sh
printf '%s\n' "$NVA_PASS"
ASKPASS
chmod 700 "$tmp/askpass"
export SSH_ASKPASS="$tmp/askpass" SSH_ASKPASS_REQUIRE=force

echo "→ vyos@$host 에 설정 적용"
ssh -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no "vyos@$host" \
  'cat > /tmp/vyos-config.sh && chmod +x /tmp/vyos-config.sh && sg vyattacfg -c /tmp/vyos-config.sh; rc=$?; rm -f /tmp/vyos-config.sh; exit $rc' \
  < "$tmp/vyos-config.sh"
