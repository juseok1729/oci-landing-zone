#!/usr/bin/env bash
# scripts/vyos.sh 를 SSH 로 NVA(VyOS)에 보내 실행한다.  scripts/vyos-apply.sh
#   비밀번호는 repo 루트 .env.local 의 NVA_PASS.
#   주소는 NVA_HOST 가 있으면 그것 (.env.local 에 둬도 된다), 없으면 terraform output nva_ssh_host 의 NVA (NVA=<이름> 으로 바꾼다).
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"

set -a; . "$dir/../.env.local"; set +a
: "${NVA_PASS:?.env.local 에 NVA_PASS 가 없습니다}"
host="${NVA_HOST:-$(terraform -chdir="$dir/../stacks/30-nva" output -json nva_ssh_host | jq -er --arg n "${NVA:-NVA}" '.[$n]')}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 비밀번호는 파일에 쓰지 않는다: ssh 가 SSH_ASKPASS 를 실행하면 환경변수 NVA_PASS 를 출력한다
cat > "$tmp/askpass" <<'ASKPASS'
#!/bin/sh
printf '%s\n' "$NVA_PASS"
ASKPASS
chmod 700 "$tmp/askpass"
export SSH_ASKPASS="$tmp/askpass" SSH_ASKPASS_REQUIRE=force

echo "→ vyos@$host 에 scripts/vyos.sh 적용"
ssh -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no "vyos@$host" \
  'cat > /tmp/vyos.sh && chmod +x /tmp/vyos.sh && sg vyattacfg -c /tmp/vyos.sh; rc=$?; rm -f /tmp/vyos.sh; exit $rc' \
  < "$dir/vyos.sh"
