#!/bin/vbash
# VyOS 설정 스크립트. stacks/30-nva/vyos.sh.tftpl 을 terraform 없이 쓰도록 값을 맨 위 변수로 뺀 것이다.
# VyOS 에 올려서 실행한다 (비밀번호는 .env.local 의 NVA_PASS):
#   scp scripts/vyos.sh vyos@<mgmt 공인 IP>:
#   ssh vyos@<mgmt 공인 IP>
#   sg vyattacfg -c ./vyos.sh
# 로컬에서 한 번에 보내 실행하려면 scripts/vyos-apply.sh
# 값은 2026-11-25 apply 기준이다. NVA 를 다시 만들면 MAC 이 바뀌므로 terraform output nva_vnics 로 고친다.
# N.B. NAT-INSIDE, VCN-PRD, VCN-NONPRD, VCN-MGMT 그룹 말고는 set 만 하므로, 여기서 지운 줄은 장비에서 지워지지 않는다 (delete 줄을 따로 넣는다).
# N.B. make configure-nva 도 같은 설정을 덮어쓴다. 이 스크립트를 고쳐 쓰면 configure-nva 는 쓰지 않는다.
source /opt/vyatta/etc/functions/script-template

# ── 변수 ──────────────────────────────────────────────────────
# VNIC 이름 → 인터페이스, MAC (OCI VNIC MAC. hw-id 로 eth 번호를 고정한다)
declare -A ETH=([mgmt]=eth0 [untrust]=eth1 [trust]=eth2)
declare -A MAC=([mgmt]=02:00:17:00:9f:59 [untrust]=02:00:17:01:a3:36 [trust]=02:00:17:00:45:49)
# 주소 (공백으로 여러 개). mgmt(eth0)는 이미지 설정(DHCP, VRF MGMT)을 그대로 쓰므로 넣지 않는다
declare -A ADDR=([untrust]='10.0.0.117/24' [trust]='10.0.16.70/24 10.0.16.160/24')
GW_UNTRUST=10.0.0.1 # subnet 의 VCN 라우터 (subnet 첫 IP)
GW_TRUST=10.0.16.1
PRD=(10.1.0.0/16 10.4.0.0/16)    # ec-prd, erp-prd
NONPRD=(10.2.0.0/16 10.5.0.0/16) # ec-dev, erp-dev
MGMT=(10.3.0.0/16)               # mgmt: 모든 VCN 과 통신하고 node-exporter 를 읽는다
WAF=10.0.64.0/24
DNS=10.0.80.0/24
HQ=192.168.10.0/24

SPOKES=("${PRD[@]}" "${NONPRD[@]}" "${MGMT[@]}")
EXPORTER_IP=${ADDR[trust]%%/*} # trust 첫 주소

# ── 설정 ──────────────────────────────────────────────────────
configure

# 인터페이스: hw-id(= OCI VNIC MAC)로 이름을 고정해 재부팅해도 eth 번호가 바뀌지 않게 한다
for n in "${!ETH[@]}"; do
  set interfaces ethernet "${ETH[$n]}" hw-id "${MAC[$n]}"
  set interfaces ethernet "${ETH[$n]}" description "$n"
  for a in ${ADDR[$n]}; do
    set interfaces ethernet "${ETH[$n]}" address "$a"
  done
done
# ha 는 VNIC 이 있을 때만 (ETH 에 ha 가 없으면 건너뛴다)
set interfaces ethernet "${ETH[trust]}" mtu '9000'
[[ -n ${ETH[ha]:-} ]] && set interfaces ethernet "${ETH[ha]}" mtu '9000'

# 메인 테이블: 인터넷은 untrust, 내부(spoke, WAF, DNS, HQ)는 trust 의 VCN 라우터로
set protocols static route 0.0.0.0/0 next-hop "$GW_UNTRUST"
for c in "${SPOKES[@]}" "$WAF" "$DNS" "$HQ"; do
  set protocols static route "$c" next-hop "$GW_TRUST"
done

# OCI DNS(169.254.169.254)는 MGMT VRF 에서만 보이므로 메인 테이블용 DNS 지정
set system name-server '1.1.1.1'

# 아래 그룹은 변수에서 다시 만든다 (spoke 를 빼거나 다른 그룹으로 옮기면 장비에서도 빠지게)
for g in NAT-INSIDE VCN-PRD VCN-NONPRD VCN-MGMT; do
  cli-shell-api exists firewall group network-group "$g" && delete firewall group network-group "$g"
done

# 인터넷 NAT: spoke 와 WAF subnet 이 untrust 로 나갈 때
for c in "${SPOKES[@]}" "$WAF"; do
  set firewall group network-group NAT-INSIDE network "$c"
done
set nat source rule 100 description 'inside-to-internet'
set nat source rule 100 outbound-interface name "${ETH[untrust]}"
set nat source rule 100 source group network-group 'NAT-INSIDE'
set nat source rule 100 translation address 'masquerade'

# 응답 트래픽 공통 허용
set firewall global-options state-policy established action 'accept'
set firewall global-options state-policy related action 'accept'
set firewall global-options state-policy invalid action 'drop'

# 운영 ↔ 비운영 차단. mgmt 는 어느 그룹에도 없으므로 모든 VCN 과 양방향으로 통신한다 (모니터링, 접근제어, DB 암호화)
for c in "${PRD[@]}"; do set firewall group network-group VCN-PRD network "$c"; done
for c in "${NONPRD[@]}"; do set firewall group network-group VCN-NONPRD network "$c"; done
set firewall ipv4 name ALLOW-ALL default-action 'accept'
set firewall ipv4 name TRUST-INTRA default-action 'accept'
set firewall ipv4 name TRUST-INTRA rule 100 action 'drop'
set firewall ipv4 name TRUST-INTRA rule 100 source group network-group 'VCN-NONPRD'
set firewall ipv4 name TRUST-INTRA rule 100 destination group network-group 'VCN-PRD'
set firewall ipv4 name TRUST-INTRA rule 110 action 'drop'
set firewall ipv4 name TRUST-INTRA rule 110 source group network-group 'VCN-PRD'
set firewall ipv4 name TRUST-INTRA rule 110 destination group network-group 'VCN-NONPRD'

# zone
set firewall zone MGMT member interface "${ETH[mgmt]}"
set firewall zone MGMT default-action 'drop'
set firewall zone UNTRUST member interface "${ETH[untrust]}"
set firewall zone UNTRUST default-action 'drop'
set firewall zone UNTRUST from TRUST firewall name 'ALLOW-ALL'
set firewall zone TRUST member interface "${ETH[trust]}"
set firewall zone TRUST default-action 'drop'
set firewall zone TRUST intra-zone-filtering firewall name 'TRUST-INTRA'
if [[ -n ${ETH[ha]:-} ]]; then
  set firewall zone HA member interface "${ETH[ha]}"
  set firewall zone HA default-action 'drop'
fi

# 모니터링: node-exporter(:9100)를 trust IP 에 띄우고 mgmt VCN(Prometheus 자리)에서만 읽게 한다.
# node-exporter 에는 allow-from 이 없고 trust SL 은 10.0.0.0/13 을 다 열어 두므로 input filter 로 막는다
set service monitoring prometheus node-exporter listen-address "$EXPORTER_IP"
for c in "${MGMT[@]}"; do set firewall group network-group VCN-MGMT network "$c"; done
set firewall ipv4 input filter rule 100 action 'accept'
set firewall ipv4 input filter rule 100 protocol 'tcp'
set firewall ipv4 input filter rule 100 destination port '9100'
set firewall ipv4 input filter rule 100 source group network-group 'VCN-MGMT'
set firewall ipv4 input filter rule 110 action 'drop'
set firewall ipv4 input filter rule 110 protocol 'tcp'
set firewall ipv4 input filter rule 110 destination port '9100'

commit
save
exit
