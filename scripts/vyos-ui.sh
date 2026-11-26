#!/usr/bin/env bash
# VyOS 의 설정, 룰 카운터, 인터페이스와 경로 상태를 SSH 로 읽어 조회용 웹 페이지(scripts/out/vyos-<host>.html)를 만든다.
#   scripts/vyos-ui.sh          다시 실행하면 그 시점 값으로 새로 만든다 (페이지는 실시간이 아니다)
#   NVA_HOST, NVA 는 vyos-apply.sh 와 같다. 장비에서는 show, nft list, ip 만 실행하고 설정은 바꾸지 않는다.
# N.B. 결과 페이지에 사설 IP, MAC, 룰이 그대로 들어 있다. out/ 은 git 에서 빠지게 해 두었고, 밖으로 공유하지 않는다.
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

echo "→ vyos@$host 에서 읽는 중"
ssh -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no "vyos@$host" '
W=/opt/vyatta/bin/vyatta-op-cmd-wrapper
printf "{\"config\":"; $W show configuration json
printf ",\"nft\":"; sudo nft -j list ruleset
printf ",\"ip\":"; ip -j addr
printf ",\"route\":"; ip -j route
printf ",\"uptime\":%s" "$(cut -d" " -f1 /proc/uptime)"
printf ",\"version\":\"%s\"}" "$($W show version | sed -n "s/^Version: *//p")"' > "$tmp/raw.json"

# jq 가 JSON 을 검증한다. </ 는 <\/ 로 바꿔 <script> 안에 넣어도 태그가 닫히지 않게 한다
mkdir -p "$dir/out"
echo '*' > "$dir/out/.gitignore"
out="$dir/out/vyos-$host.html"
jq -c --arg host "$host" --arg at "$(date '+%Y-%m-%d %H:%M:%S %Z')" '. + {host: $host, fetched: $at}' "$tmp/raw.json" \
  | sed 's#</#<\\/#g' > "$tmp/data.json"
awk -v f="$tmp/data.json" '/^__DATA__$/ { while ((getline l < f) > 0) print l; next } 1' "$dir/vyos-ui.html" > "$out"
echo "→ $out"
