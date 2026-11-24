# OCI Hub & Spoke Landing Zone (YAML-driven Terraform)

![Terraform](https://img.shields.io/badge/Terraform-~%3E%201.12-844FBA?logo=terraform&logoColor=white)
![oracle/oci](https://img.shields.io/badge/oracle%2Foci-9.13.0-C74634?logo=oracle&logoColor=white)
![hashicorp/time](https://img.shields.io/badge/hashicorp%2Ftime-0.14.2-844FBA?logo=hashicorp&logoColor=white)
![OCI backend](https://img.shields.io/badge/state-OCI%20Object%20Storage-C74634?logo=oracle&logoColor=white)

**YAML 이 곧 설계서, Terraform 은 그 YAML 을 읽어 리소스로 바꾸는 범용 엔진.**  
실제 값(CIDR, 이름, 규칙)은 전부 `config/`에 있고, `.tf`코드는 YAML 을 읽어 `for_each`로 리소스를 만드는 역할만 한다.
즉, 설계서의 구조(compartment HUB / E-COMMERCE / ERP / MGMT, VCN 6개)를 **YAML 만 고쳐서** 운영할 수 있다.

## Table of contents

- [Overview](#overview)
- [Quick Start](#quick-start)
  - [자격증명 없이 테스트](#자격증명-없이-테스트)
- [Examples](#examples)
  - [Subnet](#subnet)
  - [Route table (subnet 용)](#route-table-subnet-용)
  - [Gateway 와 gateway 용 route table](#gateway-와-gateway-용-route-table)
  - [Security List: 프로토콜별](#security-list-프로토콜별)
  - [NSG: NSG 참조](#nsg-nsg-참조)
  - [spoke 대역 한 번에 쓰기 (`spokes`)](#spoke-대역-한-번에-쓰기-spokes)
  - [DRG route table (`config/drg.yaml`) 과 spoke attachment](#drg-route-table-configdrgyaml-과-spoke-attachment)
  - [새 spoke VCN](#새-spoke-vcn)
  - [Compartment / bucket](#compartment--bucket)
- [NVA (VyOS)](#nva-vyos)
- [모니터링 (Prometheus, Grafana)](#모니터링-prometheus-grafana)
- [수정하면 재생성되는 항목](#수정하면-재생성되는-항목)
- [YAML 표기법](#yaml-표기법)
- [검증 (plan 단계)](#검증-plan-단계)
- [운영시](#운영시)
- [내부 구조 메모 (modules/, stacks/ 를 고칠 사람용)](#내부-구조-메모-modules-stacks-를-고칠-사람용)

## Overview

> [!IMPORTANT]
> 팀원은 `config/` 아래 YAML 만 수정한다. `modules/`, `stacks/` 는 관리자(owner)만 손댄다.

```
oci-landing-zone/
├── config/                 ← 일상 변경은 여기만
│   ├── compartments.yaml
│   ├── drg.yaml            DRG, DRG route table
│   ├── buckets.yaml
│   ├── nvas.yaml           NVA(VyOS) 인스턴스, VNIC
│   ├── mon.yaml            모니터링 VM (Prometheus, Grafana)
│   └── vcns/
│       ├── hub.yaml        VCN 1개 = 파일 1개 = stack 1개
│       ├── ec-prd.yaml     hub 외 파일은 전부 spoke (파일 이름 = workspace 이름 = make target)
│       ├── ec-dev.yaml
│       ├── erp-prd.yaml
│       ├── erp-dev.yaml
│       └── mgmt.yaml
├── stacks/                 state 를 나눈 실행 단위 (얇은 루트 모듈)
│   ├── 00-iam/             compartment            (홈 리전)        state: lz/iam.tfstate
│   ├── 10-hub/             DRG, HUB_VCN, bucket 전부               state: lz/hub.tfstate
│   ├── 20-spoke/           spoke VCN              (workspace 별)   state: tf-state-env/<spoke 이름>/lz/spoke.tfstate
│   ├── 30-nva/             NVA 인스턴스, VNIC, reserved IP            state: lz/nva.tfstate
│   │   ├── vyos.sh.tftpl   VyOS 설정 템플릿 (make configure-nva)
│   │   ├── configure.sh    SSH 로 설정 적용
│   │   └── vnic/           secondary VNIC 을 순서대로 붙이는 module
│   └── 40-mon/             모니터링 VM, NSG, OCI Bastion            state: lz/mon.tfstate
│       └── cloud-init.yaml.tftpl  Prometheus, Grafana 컨테이너
├── modules/
│   ├── config/             YAML 읽기 + 알 수 없는 키(오타) 검사
│   ├── compartments/
│   ├── network/            VCN, Gateway, DRG, Route table, Security list, NSG, Subnet
│   └── buckets/
├── tests/fixtures/         테스트용 YAML
├── .env.local              NVA_PASS (git 에 올리지 않음)
└── Makefile
```

## Quick Start

> [!IMPORTANT]
> state 버킷은 Terraform 이 만들지 않는다. **Versioning 을 활성화한 버킷을 먼저 만들고** 시작한다.
> `backend.hcl` 에는 `key` 를 넣지 않는다 (i.e., stack 마다 `main.tf` 에 고정돼 있다).

```bash
cp terraform.tfvars.example terraform.tfvars   # tenancy_ocid, region, profile, state_bucket/namespace
cp backend.hcl.example backend.hcl             # state 버킷 (미리 생성 + Versioning). key 는 넣지 않음

make init
make apply-iam        # 1. compartment (HUB, E-COMMERCE, ERP, MGMT)
make apply-hub        # 2. DRG, DRG route table, HUB_VCN, bucket 전부
make apply-ec-prd     # 3. spoke (ec-dev, erp-prd, erp-dev, mgmt 도 같은 방식. spoke 끼리는 순서 무관)
make apply-nva        # 4. NVA (VyOS)
make configure-nva    # 5. VyOS 설정 (SSH 비밀번호: .env.local 의 NVA_PASS)
make apply-hub        # 6. hub 의 enabled: auto rule(→ NVA)이 켜진다. 한 줄로: make apply-nva configure-nva apply-hub
make apply-mon        # 7. 모니터링 VM (Prometheus, Grafana) + Bastion. mgmt, nva 다음
# 또는 make apply-all  (iam → hub → spoke 전부 → nva → mon. stack 마다 yes 를 묻는다) 뒤에 make configure-nva apply-hub
# 삭제: make destroy-all (역순. compartment 는 state 에서만 빠지고 OCI 에 남음. cf. enable_delete = false)
```

지금 config 기준 stack 은 아래와 같다. spoke 의 make target 은 `config/vcns` 파일 이름에서 나온다.

| VCN 파일 | compartment | CIDR | 실행 |
| --- | --- | --- | --- |
| `hub.yaml` | HUB | `10.0.0.0/16` | `make apply-hub` |
| `ec-prd.yaml` | E-COMMERCE | `10.1.0.0/16` | `make apply-ec-prd` |
| `ec-dev.yaml` | E-COMMERCE | `10.2.0.0/16` | `make apply-ec-dev` |
| `mgmt.yaml` | MGMT | `10.3.0.0/16` | `make apply-mgmt` |
| `erp-prd.yaml` | ERP | `10.4.0.0/16` | `make apply-erp-prd` |
| `erp-dev.yaml` | ERP | `10.5.0.0/16` | `make apply-erp-dev` |

> [!TIP]
> `make apply-*` 는 plan 을 먼저 보여 주고 `yes` 를 기다린다. 따로 `make plan-*` 을 돌릴 필요는 없다.
> 바꾸지 않고 변경 내용만 보고 싶을 때 `make plan-*` 을 쓴다.

> [!WARNING]
> stack 은 **iam → hub → spoke** 순서로 apply 한다. 뒤 stack 은 앞 stack 의 state(output)를 읽으므로,
> 앞 stack 을 apply 하기 전에는 뒤 stack 의 plan 이 `make apply-iam 을 먼저 실행하세요` 같은 메시지로 멈춘다. 삭제는 반대 순서(spoke → hub → iam)다.

- Terraform **1.12 이상** (native `oci` backend). provider 버전은 각 stack 의 `.terraform.lock.hcl` 로 고정 (oracle/oci 9.x)
- 의존 방향은 **iam → hub → spoke** 하나뿐이다. 뒤 stack 은 앞 stack 의 output 을 `terraform_remote_state` 로 읽는다
  - hub, spoke ← iam: `compartment_ids`
  - spoke ← hub: `drg_ids`, `drg_route_table_ids`
  - nva ← iam, hub: `compartment_ids`, `subnet_ids`
- spoke 는 `stacks/20-spoke` 하나를 **workspace 로 나눠** 쓴다. workspace 이름 = `config/vcns/<이름>.yaml`.
  Makefile 이 `workspace select` 를 대신 한다. 직접 실행하는 명령어는 아래와 같다.

  ```bash
  cd stacks/20-spoke && terraform workspace select -or-create ec-prd && terraform plan -var-file=../../terraform.tfvars
  ```

- workspace 는 state 버킷의 `tf-state-env/<이름>/lz/spoke.tfstate` 파일이다 (iam, hub 는 workspace 없이 `lz/` 바로 아래).
  목록은 `terraform -chdir=stacks/20-spoke workspace list`, 정리는 `workspace delete <이름>` 이다 (리소스가 남은 state 는 거부된다).
- 새 spoke VCN 은 `config/vcns/<이름>.yaml` 을 추가하고 `make apply-<이름>` (Makefile 이 `config/vcns` 에서 spoke 목록을 찾는다)
- Compartment(IAM)는 홈 리전에서만 생성된다. 리소스 리전과 홈 리전이 다르면 `home_region` 지정
- 모든 리소스에 `ManagedBy=terraform`, `Stack=<iam|hub|ec-prd|...>` freeform tag 가 붙는다.

> [!CAUTION]
> `ManagedBy=terraform` 태그가 붙은 리소스를 **콘솔에서 직접 고치지 않는다.** 다음 apply 때 YAML 내용으로 되돌아간다.

### 자격증명 없이 테스트

```bash
make test        # stack 마다 terraform init -backend=false && terraform test
```

| stack | 확인하는 것 |
| --- | --- |
| 00-iam | `compartments.yaml` 의 compartment 가 모두 만들어지는지 |
| 10-hub | 실제 `hub.yaml` apply 그래프 (subnet 6, RT 7, DRG 1, attachment 1, SL 4, NSG 2, `buckets.yaml` 의 bucket 전부), privateip target, NSG, source_port, `enabled: auto` (NVA IP 유무에 따라 켜짐, 빠짐), 게이트웨이 RT 제약 위반 거부, `spokes` 펼침(`tests/fixtures/spokes`) |
| 20-spoke | ec-prd, ec-dev, erp-prd, erp-dev, mgmt apply (subnet, RT, attachment, NSG 개수, 자기 SGW 와 all-services 경로), hub 파일 선택 거부, 잘못된 YAML(`tests/fixtures/broken`) 거부, `spokes` 에서 자기 대역 제외 |
| 30-nva | 실제 `nvas.yaml` apply (secondary VNIC 3, secondary IP 1, reserved IP 1, skip source/dest check, public IP), hub 미적용 안내, 잘못된 YAML(`tests/fixtures/broken-nva`) 거부 |
| 40-mon | 실제 `mon.yaml` apply (mgmt subnet, 고정 IP, 공인 IP 없음, scrape 대상 = NVA trust IP:9100, NSG = Bastion → 22, 3000), nva 미적용 안내, 잘못된 YAML(`tests/fixtures/broken-mon`) 거부 |

다른 stack 의 state 는 테스트에서 `override_data` 로 대신한다. mock `compartment_ids` 는 `config/compartments.yaml` 의 이름을 그대로 쓰고, `tests/fixtures` 는 전용 이름 `TEST_COMP` 를 쓴다.

> [!NOTE]
> `make test` 는 OCI 에 연결하지 않고(mock provider), 선택된 workspace 와 상관없이 `default` workspace 로 돈다.
> config 를 고친 뒤 apply 전에 돌리면 YAML 오류와 리소스 개수 변화를 먼저 잡을 수 있다.

## Examples

아래 조각은 `config/vcns/<파일>.yaml` 의 VCN 아래(들여쓰기 2칸)에 넣고 `make apply-<stack>` 으로 반영한다.
이름은 예시다. 전체 키는 「YAML 표기법」, 기본값은 「기본값」 표를 본다.

### Subnet

```yaml
  subnets:
    HUB_APP_PRI_SBN:                          # private subnet (public 생략 = false)
      cidr: 10.0.96.0/24
      route_table: HUB_APP_PRI_RT
      security_lists: [default, HUB_APP_SL]   # default = VCN Default Security List
      dns_label: app
    HUB_EDGE_PUB_SBN:                         # public subnet. N.B. 만든 뒤 public/private 변경은 재생성
      cidr: 10.0.112.0/24
      public: true
      route_table: HUB_EDGE_PUB_RT
      dns_label: edge
    HUB_TMP_PRI_SBN:                          # route_table / security_lists 생략 → VCN 기본 RT + Default SL
      cidr: 10.0.128.0/24
      display_name: hub-tmp-subnet            # OCI 표시 이름만 다르게 (키는 그대로)
```

> [!WARNING]
> subnet 의 `public` 과 `dns_label` 은 만든 뒤 바꾸면 **subnet 이 삭제 후 재생성**된다.
> 안에 인스턴스나 LB 가 있으면 삭제가 실패하므로 처음에 정해 둔다.

### Route table (subnet 용)

```yaml
  route_tables:
    HUB_APP_PRI_RT:
      rules:
        - destination: 192.168.10.0/24                          # 대상 1개 → destination
          target: drg:HUB_DRG
          description: "HQ VPN"
        - destinations: [10.1.0.0/16, 10.2.0.0/16]             # 대상 여러 개 → destinations (같은 target)
          target: drg:HUB_DRG
          description: "ec-prd, ec-dev VCN"
        - destination: spokes                                   # spoke VCN CIDR 전체 (config/vcns 의 hub 외 파일)
          target: drg:HUB_DRG
          description: "spoke VCN"
        - destination: all-services                             # OCI 서비스 전체(OSN) → SGW. SGW services 와 같아야 함
          target: sgw:HUB_SGW
        - destination: 0.0.0.0/0                                # NVA VIP 로
          target: privateip:10.0.16.160
          enabled: auto                                         # IP 가 있을 때만 켜짐. false = 끄기 (i.e., 지우지 않고 보관)
    HUB_EDGE_PUB_RT:
      rules:
        - destination: 0.0.0.0/0
          target: igw:HUB_IGW
```

> [!IMPORTANT]
> `privateip:` target 은 `enabled: true` 면 그 IP 가 **실제로 있어야** plan 이 통과한다. `enabled: auto` 는 IP 가 있을 때만 rule 을 넣고 없으면 뺀다
> (i.e., NVA 를 만든 뒤 `make apply-hub` 하면 켜지고, NVA 를 지운 뒤 `make apply-hub` 하면 빠진다). 대상 VNIC 에는 **Skip source/destination check** 가 활성화되어 있어야 트래픽이 지나간다.

### Gateway 와 gateway 용 route table

```yaml
# config/vcns/hub.yaml
  internet_gateways:
    HUB_IGW: {}                               # enabled: false 로 두면 IGW 는 남기고 트래픽만 차단

  service_gateways:
    HUB_SGW:
      services: all-services                  # 또는 objectstorage. hub 안의 리소스(NVA, WAF, DNS)용
      route_table:                            # SGW 로 들어온 트래픽이 갈 곳. target 은 drg: / privateip: 만
        name: HUB_SGW_RT                      # 지금은 rule 없음 (아래 WARNING)

  drg_attachment:
    name: HUB_DRG_ATT
    drg: HUB_DRG
    drg_route_table: autogenerated            # DRG 쪽 테이블 (drg.yaml 의 이름 또는 autogenerated)
    route_table:                              # DRG → VCN 으로 들어올 때. target 은 sgw: / privateip: 만
      name: HUB_INGRESS_RT
      rules:
        - destination: spokes                 # spoke ↔ spoke 를 NVA 로
          target: privateip:10.0.16.160
          enabled: auto
```

```yaml
# config/vcns/ec-prd.yaml: OCI 서비스는 자기 SGW 로, 나머지는 hub 로
  service_gateways:
    EC_PRD_SGW:
      services: all-services

  route_tables:
    EC_PRD_RT:
      rules:
        - destination: all-services           # 0.0.0.0/0 보다 구체적이라 먼저 맞는다
          target: sgw:EC_PRD_SGW
        - destination: 0.0.0.0/0
          target: drg:HUB_DRG
```

> [!NOTE]
> spoke 마다 SGW 를 두는 이유: OCI 는 요청이 어느 VCN 의 SGW 로 들어왔는지 보므로 IAM network source 로 spoke VCN 별 접근 제어를 할 수 있고,
> hub 경로 장애가 spoke 의 OCI 서비스 접근으로 번지지 않는다. hub SGW 를 거치는 transit 이 필요하면 (e.g., 본사 → OCI 서비스)
> `service_gateways.<SGW>.route_table:` 의 rule (target `drg:` / `privateip:`) 과 `HUB_INGRESS_RT` 의 `all-services → sgw:` rule 로 만든다.

> [!WARNING]
> OCI 는 SGW 에 한 번 붙인 route table 을 떼지 못하게 한다 (다른 테이블로 바꾸기만 된다). YAML 에서 `route_table:` 을 지우면
> provider 가 연결 해제를 보내지 않아 plan 은 RT 삭제만 잡고, apply 는 `409-Conflict, Gateway entity ... using the route table exists` 로 실패한다.
> 필요 없어진 SGW route table 은 지우지 말고 `rules` 만 비운다.

### Security List: 프로토콜별

```yaml
  security_lists:
    HUB_APP_SL:
      ingress:
        - { source: 192.168.10.0/24, protocol: tcp, port: "443" }             # TCP 단일 포트
        - { source: 192.168.10.0/24, protocol: tcp, port: "8080-8090" }       # TCP 포트 범위
        - { source: 10.1.0.0/16, protocol: tcp }                              # TCP 전체 포트 (port 생략)
        - { source: 192.168.10.0/24, protocol: udp, port: "53" }              # UDP
        - { source: 0.0.0.0/0, protocol: icmp, icmp_type: 3, icmp_code: 4 }   # ICMP Path MTU Discovery
        - { source: 192.168.10.0/24, protocol: icmp, icmp_type: 8 }           # ping (echo request, code 전체)
        - { source: 10.0.0.0/16, protocol: icmp }                             # ICMP 전체
        - { source: 10.3.0.0/16 }                                             # 모든 프로토콜 (protocol 생략 = all)
        - { source: 192.168.20.0/24, protocol: udp, port: "53", stateless: true }  # stateless. N.B. 응답용 egress 도 필요
      egress:
        - { destination: all-services, protocol: tcp, port: "443" }           # OCI 서비스(OSN) 로 HTTPS
        - { destination: objectstorage, protocol: tcp, port: "443" }          # Object Storage 만
        - { destination: 192.168.20.0/24, protocol: udp, source_port: "53", stateless: true }  # 위 stateless 의 응답
        - { destination: 0.0.0.0/0 }                                          # 모든 곳, 모든 프로토콜
```

- SL / NSG 규칙은 source / destination 이 **1개씩**이다. 여러 대역이면 줄을 나눈다 (`destinations` 는 route rule 전용).
- subnet 의 `security_lists: [default, ...]` 로 붙인다.

> [!TIP]
> 기본은 stateful 이라 응답 트래픽은 자동 허용된다. `stateless: true` 일 때만 반대 방향 규칙을 따로 적는다.

> [!WARNING]
> subnet 의 `security_lists` 에서 `default` 를 빼면 Default SL 의 **egress 전체 허용도 같이 빠진다.**
> 직접 만든 SL 에 egress 규칙이 없으면 그 subnet 에서 나가는 트래픽이 모두 막힌다.

### NSG: NSG 참조

```yaml
  network_security_groups:
    HUB_LB_NSG:
      ingress:
        - { source: 0.0.0.0/0, protocol: tcp, port: "443" }
      egress:
        - { destination: nsg:HUB_APP_NSG, protocol: tcp, port: "8080" }       # destination 에 NSG (LB → APP)
    HUB_APP_NSG:
      ingress:
        - { source: nsg:HUB_LB_NSG, protocol: tcp, port: "8080" }             # source 에 NSG (LB 에서 오는 것만)
        - { source: nsg:HUB_APP_NSG, protocol: tcp, port: "7000-7100" }       # 자기 자신 = 같은 NSG 의 VNIC 끼리
        - { source: 192.168.10.0/24, protocol: tcp, port: "22" }              # CIDR 와 섞어 써도 됨
      egress:
        - { destination: nsg:HUB_DB_NSG, protocol: tcp, port: "3306" }
        - { destination: all-services, protocol: tcp, port: "443" }
    HUB_DB_NSG:
      ingress:
        - { source: nsg:HUB_APP_NSG, protocol: tcp, port: "3306" }
```

- `nsg:<이름>` 은 **같은 VCN 의 NSG 만** 된다. Security List 에서는 못 쓴다 (plan 단계에서 막힌다).
- VNIC 에는 subnet 의 SL 과 NSG 규칙이 **합쳐서** 적용된다. 하나라도 허용하면 통과한다.

> [!NOTE]
> NSG 는 만들기만 하고 OCID 를 output `nsg_ids` 로 내보낸다. VNIC(인스턴스, LB)에 붙이는 것은 배포 쪽에서 한다.

### spoke 대역 한 번에 쓰기 (`spokes`)

spoke 대역을 CIDR 로 나열하는 대신 `spokes` 라고 쓴다. `config/vcns` 의 hub 외 파일에 있는 VCN CIDR 전부로 펼쳐지므로
spoke 를 추가, 삭제해도 이 rule 은 고치지 않는다.

```yaml
# config/vcns/hub.yaml: NVA 가 검사한 트래픽을 spoke 전체로
  route_tables:
    HUB_FW_TRUST_PRI_RT:
      rules:
        - destination: spokes                     # → 10.1, 10.2, 10.3, 10.4, 10.5 (/16)
          target: drg:HUB_DRG
```

```yaml
# config/vcns/mgmt.yaml: spoke 안에서 쓰면 자기 대역은 빠진다
    MGMT_BASTION_PUB_RT:
      rules:
        - destinations: [10.0.0.0/16, spokes]     # → 10.0, 10.1, 10.2, 10.4, 10.5 (MGMT 의 10.3 은 빠짐)
          target: drg:HUB_DRG
```

| 쓴 곳 | 쓴 값 | 펼친 결과 (지금 config, 모두 `/16`) |
| --- | --- | --- |
| hub 의 route rule | `spokes` | `10.1`, `10.2`, `10.3`, `10.4`, `10.5` |
| mgmt 의 route rule | `[10.0.0.0/16, spokes]` | `10.0`, `10.1`, `10.2`, `10.4`, `10.5` |
| `drg.yaml` 의 DRG route rule | `[10.0.0.0/16, spokes]` | `10.0`, `10.1`, `10.2`, `10.3`, `10.4`, `10.5` |

펼친 결과는 plan 의 `Changes to Outputs` 에 `rule_destinations` 로 나온다. apply 뒤에는 아래 명령어로 다시 본다.

```bash
terraform -chdir=stacks/10-hub output rule_destinations
```

> [!NOTE]
> `spokes` 는 route rule(VCN, DRG) 전용이다. SL / NSG 규칙에 쓰면 형식 오류로 막힌다.
> `spokes` 에 hub 대역(`10.0.0.0/16`)은 들어가지 않는다. 필요하면 위처럼 따로 적고, `spokes` 와 같은 대역을 또 적으면 중복 destination 오류가 난다.

### DRG route table (`config/drg.yaml`) 과 spoke attachment

```yaml
# config/drg.yaml
drgs:
  HUB_DRG:
    compartment: HUB
    route_tables:
      DRG_SPOKE_RT:
        rules:
          - destination: 0.0.0.0/0
            next_hop: HUB_DRG_ATT             # DRG attachment 이름 (hub stack 의 attachment 만)
      DRG_IPSEC_RT:
        rules:
          - destinations: [10.0.0.0/16, spokes]   # HUB + spoke 전체
            next_hop: HUB_DRG_ATT
```

```yaml
# config/vcns/ec-prd.yaml
  drg_attachment:
    name: EC_PRD_DRG_ATT
    drg: HUB_DRG                              # hub stack 이 만든 DRG
    drg_route_table: DRG_SPOKE_RT
```

### 새 spoke VCN

`config/vcns/stg.yaml` 을 만들고 `make apply-stg`. Makefile 은 고치지 않는다 (i.e., `config/vcns` 의 hub 외 파일이 곧 spoke 목록이다).
순서는 아래와 같다.

```bash
# 1. 새 compartment 를 쓰면 config/compartments.yaml 에 STG 를 추가하고
make apply-iam

# 2. config/vcns/stg.yaml 작성 (아래 예시) + stacks/20-spoke/tests/spoke.tftest.hcl 에 run 추가 (ec_prd_applies 복사)
make test

# 3. hub 먼저: spokes 로 적은 rule 에 10.6.0.0/16 이 추가되는지 plan 의 rule_destinations 로 확인
make apply-hub

# 4. 새 spoke
make apply-stg

# 5. NVA 에 새 대역 반영 (경로, NAT, 그룹)
make configure-nva
```

```yaml
STG_VCN:
  compartment: STG                            # compartments.yaml 에도 추가 → make apply-iam 먼저
  cidrs: [10.6.0.0/16]                        # 다른 VCN 과 겹치지 않게 (지금 10.0 ~ 10.5 사용 중)
  dns_label: stg

  service_gateways:
    STG_SGW:                                  # OCI 서비스는 hub 를 거치지 않고 자기 SGW 로
      services: all-services

  drg_attachment:
    name: STG_DRG_ATT
    drg: HUB_DRG
    drg_route_table: DRG_SPOKE_RT

  route_tables:
    STG_RT:
      rules:
        - destination: all-services
          target: sgw:STG_SGW
        - destination: 0.0.0.0/0
          target: drg:HUB_DRG

  subnets:
    STG_APP_PRI_SBN:
      cidr: 10.6.0.0/24
      route_table: STG_RT
      dns_label: app
```

spoke test 에 run 을 추가하지 않으면 `make test` 는 새 파일을 검사하지 않는다 (오류는 `make plan-stg` 에서야 드러난다).

> [!IMPORTANT]
> hub 쪽 route rule 과 `drg.yaml` 이 spoke 대역을 `spokes` 로 적고 있으면 새 spoke 의 대역(`10.6.0.0/16`)은 자동으로 들어간다.
> CIDR 을 직접 나열한 rule 이 있으면 그 목록에도 추가해야 응답이 돌아온다. 어느 쪽이든 hub 를 먼저 `make apply-hub` 한 뒤 `make apply-stg` 한다.
> NVA(VyOS)의 경로, NAT, 그룹은 `make configure-nva` 를 다시 실행하면 새 대역이 들어간다.

### Compartment / bucket

```yaml
# config/compartments.yaml
compartments:
  STG:
    description: "스테이징"
  SHARED:
    ocid: ocid1.compartment.oc1..aaaa...      # 이미 있는 compartment (i.e., 만들지 않고 참조만)
```

```yaml
# config/buckets.yaml: 어느 compartment 든 hub stack 이 만든다 (make apply-hub)
buckets:
  STG-APP-LOG-01:
    compartment: STG
  MGMT-ARCHIVE-01:
    compartment: MGMT
    storage_tier: Archive                     # Standard | Archive
    versioning: true
```

**compartment 하나로 운영하기**: 모든 VCN, bucket 이 같은 compartment 키를 가리키게 하면 된다. 코드는 고치지 않는다.

```yaml
# config/compartments.yaml
compartments:
  LZ_COMP:
    description: "랜딩존"

# config/vcns/*.yaml (VCN 파일마다)
EC_PRD_VCN:
  compartment: LZ_COMP

# config/buckets.yaml
buckets:
  EC-PRD-CONNECTOR-SYSLOG-TO-BUCKET-01:
    compartment: LZ_COMP                      # 그래도 hub stack 이 만든다
```

> [!NOTE]
> 테스트는 `config/compartments.yaml` 을 읽으므로 compartment 구성을 바꿔도 테스트는 고치지 않는다.
> 고칠 곳은 리소스 개수 assert (e.g., hub subnet 6, ec-prd NSG 3) 다. VCN 설계를 바꾸면 `stacks/*/tests/*.tftest.hcl` 의 해당 숫자를 같이 고친다.

## NVA (VyOS)

FortiGate 대신 VyOS 인스턴스(NVA)를 `stacks/30-nva` 로 만들고, VyOS 설정까지 make 로 넣는다. 순서는 아래와 같다.

```bash
make apply-nva                                      # 1. 인스턴스 + VNIC 4개 + secondary IP + reserved IP
terraform -chdir=stacks/30-nva output nva_vnics     #    (선택) VNIC 별 IP, MAC 확인
make configure-nva                                  # 2. VyOS 설정 (SSH, .env.local 의 NVA_PASS)
make apply-hub                                      # 3. hub 의 enabled: auto rule 이 NVA 로 켜진다
# 한 줄로: make apply-nva configure-nva apply-hub
```

| 단계 | 하는 일 | 고칠 파일 |
| --- | --- | --- |
| `apply-nva` | `config/nvas.yaml` 대로 인스턴스를 만들고, 부팅이 끝난 뒤(180초) secondary VNIC 을 YAML 순서대로 하나씩 붙인다. 그래서 VyOS 에서 eth0 = mgmt(primary), eth1 = untrust, eth2 = trust, eth3 = ha 가 된다 | `config/nvas.yaml` |
| `configure-nva` | 설정 스크립트(output `vyos_config`)를 mgmt 공인 IP 로 보내 `commit`, `save` 한다. 인터페이스 주소, hw-id(MAC), 게이트웨이, spoke 경로, NAT, VCN-PRD/NONPRD/MGMT 그룹은 config 에서 채운다 | `stacks/30-nva/vyos.sh.tftpl` |
| `apply-hub` | `privateip:10.0.16.160` 을 target 으로 쓰는 rule(`enabled: auto`)을 켠다 | `config/vcns/hub.yaml` |

SSH 는 비밀번호 인증이다 (이미지가 그렇게 구성돼 있어 SSH 키는 넣지 않는다). 비밀번호는 repo 루트 `.env.local` 에 두고, 이 파일은 `.gitignore` 에 있다.

```bash
# .env.local
NVA_PASS="<vyos 사용자 비밀번호>"
```

> [!WARNING]
> `make apply-hub` 는 `make configure-nva` **다음에** 한다. NVA IP 가 생긴 뒤 hub 를 apply 하면 rule 이 바로 켜지는데,
> VyOS 설정 전이면 spoke 의 인터넷, spoke 간 통신이 끊긴다.

- **VyOS 설정 변경**: `stacks/30-nva/vyos.sh.tftpl` 을 고치고 `make apply-nva configure-nva` 를 실행한다 (apply 가 output `vyos_config` 를 갱신한다). `NAT-INSIDE`, `VCN-PRD`, `VCN-NONPRD`, `VCN-MGMT` 그룹은 매번 다시 만들고, 나머지는 `set` 만 하므로 템플릿에서 지운 설정은 장비에서 직접 `delete` 한다.
- **spoke 추가**: 경로, NAT, 그룹은 템플릿을 고치지 않아도 따라온다. `make apply-nva configure-nva` 만 다시 실행한다.
- **VCN 간 차단**: `config/vcns` 파일 이름이 `prd` 로 끝나면 VCN-PRD, `mgmt` 를 뺀 나머지 spoke 는 VCN-NONPRD 이고, 두 그룹 사이는 NVA 가 막는다. `mgmt` 는 어느 그룹에도 없어 모든 VCN 과 양방향으로 통신한다 (모니터링, 접근제어, DB 암호화 솔루션 자리).
- **모니터링**: VyOS 의 node-exporter 가 trust IP `10.0.16.11:9100` 에서 지표(인터페이스 bps, CPU, 메모리, conntrack)를 내보낸다. trust SL 은 10.0.0.0/13 을 다 열어 두므로 VyOS input filter 로 mgmt VCN(`VCN-MGMT`)만 허용한다. 수집, 화면은 [모니터링](#모니터링-prometheus-grafana) 의 40-mon 이 한다.
- **eth 번호 확인**: VyOS 의 `show interfaces` MAC 과 `nva_vnics` output 의 `mac` 을 대조한다.
- **다시 만들기**: `make destroy-nva && make apply-nva configure-nva apply-hub`. reserved IP 도 지워져 공인 IP 가 바뀐다. 전에 쓰던 공인 IP 를 다시 받으면 SSH host key 불일치로 접속이 거부되니 `ssh-keygen -R <IP>` 로 지운다.

> [!NOTE]
> `make apply-all` 은 hub 를 nva 보다 먼저 apply 하므로 그때는 auto rule 이 빠진 채로 만들어진다. 끝난 뒤 `make configure-nva apply-hub` 를 실행한다.

## 모니터링 (Prometheus, Grafana)

`stacks/40-mon` 이 `config/mon.yaml` 대로 mgmt 의 `MGMT_MON_PRI_SBN` 에 VM 1대를 만든다. VM 은 cloud-init 으로 Prometheus 와 Grafana 컨테이너를 띄우고, Prometheus 는 NVA 의 trust IP:9100 (VyOS node-exporter) 을 scrape 한다. 공인 IP 는 없고, Grafana 는 같은 subnet 의 OCI Bastion 으로 port forwarding 해서 연다.

```bash
make configure-nva                                       # 1. VyOS 에 node-exporter 가 들어 있어야 한다
make apply-mon                                           # 2. VM + NSG + Bastion
terraform -chdir=stacks/40-mon output -raw grafana_tunnel  # 3. 터널 명령 2줄: session 을 만들고, 나온 OCID 로 ssh -L
# 4. 브라우저로 http://localhost:3000 (admin / admin, 첫 로그인에 바꾼다) → Dashboards → Import → 1860 (Node Exporter Full)
```

| 무엇 | 어디서 | 고칠 파일 |
| --- | --- | --- |
| VM 크기, IP, subnet, 접속 허용 대역 | `make apply-mon` | `config/mon.yaml` |
| scrape 대상 | 30-nva state 의 `nva_vnics` 에서 이름이 `trust` 인 VNIC IP | (자동) |
| Prometheus, Grafana 버전, 설정 | cloud-init (첫 부팅에만 돈다) | `stacks/40-mon/cloud-init.yaml.tftpl` |

> [!WARNING]
> cloud-init 내용(scrape 대상 포함)이 바뀌면 `make apply-mon` 이 VM 을 **다시 만든다** (첫 부팅에만 돌기 때문). Prometheus 에 쌓인 지표와 Grafana 에서 만든 대시보드, 바꾼 비밀번호도 같이 사라진다.

- **패키지, 이미지 경로**: podman 은 SGW(OCI yum)로, 컨테이너 이미지는 NVA 를 거쳐 인터넷(quay.io, docker.io)에서 받는다. NVA 가 인터넷 NAT 를 하기 전이면 컨테이너가 뜨지 않는다.
- **NSG**: Bastion private endpoint IP → 22, 3000, `grafana_from` → 3000 만 연다. Bastion session 을 열 수 있는 공인 대역은 `bastion_from` 이다.
- **SSH**: `ssh_key_file` 의 공개키가 VM(`opc`)과 Bastion session 에 같이 쓰인다. 22 도 같은 방식으로 port forwarding 한다.

## 수정하면 재생성되는 항목

> [!CAUTION]
> `yes` 를 치기 전에 plan 마지막 줄 `Plan: X to add, Y to change, Z to destroy` 의 **destroy 가 0 인지** 확인한다.
> 0 이 아니면 멈추고 `-/+` / `must be replaced` 가 붙은 리소스를 찾는다. 원인은 대부분 아래 표에 있다.

| YAML 에서 바꾸는 것 | 결과 | 영향 |
| --- | --- | --- |
| subnet `public` | **삭제 → 재생성** | subnet 안에 VNIC(인스턴스, LB …)가 있으면 삭제가 실패 |
| subnet `dns_label` | **삭제 → 재생성** | 위와 같음 |
| VCN `dns_label` | **삭제 → 재생성** | VCN 아래 subnet, RT, gateway 전부 |
| YAML **키 이름** (subnet, RT, SL, NSG, gateway, bucket) | **삭제 → 재생성** | Terraform 은 키 이름으로 리소스를 구분하므로 이름을 바꾸면 다른 리소스 |
| compartment 키 이름 | 새로 생성 + 기존 것은 state 에서만 빠짐 | `enable_delete = false` 라서 기존 compartment 는 OCI 에 남음 |
| spoke **파일 이름** (`config/vcns/<이름>.yaml`) | workspace 가 바뀌어 빈 state 에서 **전부 새로 생성** | 기존 리소스는 옛 workspace state 에 남는다. 이름을 바꾸기 전에 옛 이름으로 `make destroy-<이름>` 한다 |

제자리 수정(`~ update in-place`) 되는 것:

- route rule 추가, 삭제, `enabled`, SL / NSG 규칙, `display_name`, subnet 의 `route_table`, `security_lists`
- VCN `cidrs` 에 대역 추가
- subnet `cidr`: 시작 주소가 같아야 함 (e.g., `10.0.80.0/24` → `/23` 처럼 크기만). 쓰고 있는 IP 도 새 범위 안에 있어야 함
- NSG 규칙을 목록 **중간에** 끼우면 뒤 규칙들이 순번 키(`<NSG>|ingress|<i>`)가 밀려 줄줄이 update 된다

> [!TIP]
> NSG 규칙은 목록 **끝에 추가**하면 plan 이 새 규칙 1개 생성으로 끝난다.

근거: oracle/oci provider 의 `ForceNew` 필드 (`core_subnet_resource.go`, `core_vcn_resource.go`).
SGW, IGW, DRG attachment, bucket 의 재생성 조건은 여기 정리하지 않았으니 plan 의 `-/+` 로 판단한다.

## YAML 표기법

**route table 은 붙는 곳에 적는다.** 적힌 위치가 곧 종류이고, 종류마다 쓸 수 있는 target 이 다르다 (OCI 제약).

| 위치 | 종류 | 쓸 수 있는 target |
| --- | --- | --- |
| `route_tables:` | subnet 용 | `igw:` `sgw:` `drg:` `privateip:` |
| `service_gateways.<SGW>.route_table:` (`name`, `rules`) | Service Gateway 용 | `drg:` `privateip:` |
| `drg_attachment.route_table:` (`name`, `rules`) | DRG attachment(VCN ingress) 용 | `sgw:` `privateip:` |

게이트웨이용 RT 를 subnet 에 쓰거나, 허용되지 않은 target 을 쓰면 plan 단계에서 막힌다.
RT 를 다른 위치로 옮기면 Terraform 주소가 바뀌어 **삭제 후 재생성**된다 (YAML diff 에 그대로 드러난다).

**route rule target**

| 표기 | 의미 |
| --- | --- |
| `igw:HUB_IGW` | 같은 VCN 의 Internet Gateway |
| `sgw:HUB_SGW` | 같은 VCN 의 Service Gateway |
| `drg:HUB_DRG` | 이 VCN 이 attach 된 DRG |
| `privateip:10.0.16.160` | 같은 VCN 안의 Private IP (NVA VIP 등). IP 가 실제로 있어야 함 (`enabled: auto` 면 없을 때 빠짐) |
| `ocid1....` | OCID 직접 지정 (검사하지 않음) |

**destination**: CIDR, `all-services`(All ICN Services In OSN), `objectstorage`, `spokes`. 여러 개는 `destinations: [a, b]`

**route rule `enabled`**: `true`(기본) | `false`(끄기) | `auto`(`privateip:` target 의 IP 가 있을 때만 켜기)

**`spokes`**: `config/vcns` 의 hub 외 파일에 있는 VCN CIDR 전부로 펼쳐진다 (자기 VCN 의 CIDR 은 빠진다). VCN route rule 과 DRG route rule 에서 쓴다.
spoke 파일을 추가, 삭제하면 다음 `make apply-hub` 때 목록이 따라 바뀐다. 펼친 결과는 stack 출력 `rule_destinations` 로 확인한다 (「Examples > spoke 대역 한 번에 쓰기」).

**SL / NSG 규칙**: `source`(ingress) / `destination`(egress) 은 CIDR 또는 `all-services` / `objectstorage`.
NSG 규칙은 `nsg:<이름>` 으로 **같은 VCN 의** 다른 NSG(또는 자기 자신)도 지정할 수 있다 (Security List 는 불가).
`protocol`: all / tcp / udp / icmp. `port` = 목적지 포트, `source_port` = 출발지 포트 (`"53"` 또는 `"1024-65535"`, tcp/udp 만).

**이름 규칙**: YAML 키가 곧 OCI 표시 이름이자 Terraform 식별자다.

> [!WARNING]
> YAML 키(리소스 이름)를 바꾸면 **삭제 후 재생성**된다. 표시 이름만 바꾸려면 키는 두고 `display_name:` 을 쓴다.

**기본값**

| 항목 | 생략 시 |
| --- | --- |
| subnet `route_table` | VCN 기본 route table (규칙 없음, VCN 내부 통신만) |
| subnet `security_lists` | VCN Default Security List (`default` 를 목록에 섞어 쓸 수도 있음) |
| subnet `public` | `false` (Public IP 금지) |
| `compartment` (gateway/RT/SL/NSG/subnet) | 소속 VCN 의 compartment |
| `drg_attachment.drg_route_table` | DRG 의 Autogenerated VCN 테이블 (`autogenerated` 로 명시 가능) |
| SGW `services` | `all-services` |
| `lock_default_security_list` | `false` (Default SL 의 기본 규칙 유지, i.e., SSH 22 를 0.0.0.0/0 에서 허용) |
| bucket | `NoPublicAccess`, `Standard`, versioning 끔 |

> [!CAUTION]
> Default Security List 는 **SSH 22 를 0.0.0.0/0 에서 허용**한다. public subnet 에 `default` 를 붙이면 SSH 가 인터넷에 열린다.
> 필요 없으면 subnet 에서 `default` 를 빼거나 VCN 에 `lock_default_security_list: true` 를 쓴다.

**bucket 은 모두 hub stack 이 만든다**: compartment 와 상관없이 `make apply-hub` 가 만든다.
그래서 compartment 를 하나로 합치든 여러 개로 나누든 bucket 소유가 겹치지 않고, spoke 를 destroy 해도 bucket 은 남는다.

모든 필드는 `modules/network/variables.tf` 의 타입 정의가 곧 스키마다.

## 검증 (plan 단계)

YAML 이 잘못되면 리소스를 만들기 전에 한 번에 목록으로 보여주고 멈춘다. 각 stack 은 자기와 관련된 파일만 검사한다.

```
Error: Resource precondition failed
config/ YAML 오류 4건
  - vcns/ec-prd.yaml > EC_PRD_VCN.subnets.EC_PRD_WEB_PRI_SBN: 알 수 없는 키 'route_tabel'
  - VCN EC_PRD_VCN: compartment 'E-COMMERCEE' 가 없습니다 (compartments.yaml 과 00-iam apply 확인)
  - subnet EC_PRD_WEB_PRI_SBN: 10.2.10.0/24 이 EC_PRD_VCN CIDR(10.1.0.0/16) 범위 밖입니다
  - route table HUB_SGW_RT: Service Gateway 용 route table 은 drg: / privateip: 만 target 으로 쓸 수 있습니다 (igw:HUB_IGW)
```

검사 항목: 앞 stack 미적용(`make apply-iam 을 먼저 실행하세요` / `make apply-hub 를 먼저 실행하세요`), 알 수 없는 키(오타), compartment, route table, security list, NSG, gateway, DRG 참조,
게이트웨이 RT 의 target 제약, subnet CIDR 범위, 자기 VCN CIDR 를 DRG 로 보내는 rule, destination 중복,
dns_label 형식, 이름 중복(attachment 포함), 포트 형식, DRG next_hop, VCN 파일당 1개,
route rule `enabled` 값(`true` / `false` / `auto`, `auto` 는 `privateip:` target 만),
`nvas.yaml` 의 필수 키, compartment, hub subnet 이름, `public_ip` 값, VNIC 4개 이하, primary 의 `secondary_ips` 금지,
`mon.yaml` 의 필수 키, compartment, spoke subnet 이름.

> [!NOTE]
> 검사하지 않는 것: subnet 끼리 CIDR 겹침(apply 에서 OCI 가 거부), OCID 로 직접 쓴 target,
> route rule destination 과 SGW `services` 의 일치 여부(apply 에서 OCI 가 거부).

## 운영시

**NVA 로 보내는 rule** (`config/vcns/hub.yaml`, `enabled: auto`: NVA 의 10.0.16.160 이 있을 때만 켜짐)

| route table | rule | 역할 |
| --- | --- | --- |
| `HUB_INGRESS_RT` | `0.0.0.0/0 → privateip:10.0.16.160` | spoke → 인터넷을 NVA 로 |
| `HUB_INGRESS_RT` | spoke 대역 → `privateip:10.0.16.160` | spoke ↔ spoke 를 NVA 로 |
| `HUB_INGRESS_RT` | `10.0.64.0/24 → privateip:10.0.16.160` | DRG → WAF 를 NVA 로 |
| `HUB_FW_WAF_PRI_RT` | `0.0.0.0/0 → privateip:10.0.16.160` | WAF 의 응답을 NVA 로 |

> [!WARNING]
> 네 rule 은 같은 IP 를 보므로 함께 켜지고 함께 빠진다. `HUB_INGRESS_RT` 의 `10.0.64.0/24` 와 `HUB_FW_WAF_PRI_RT` 의 `0.0.0.0/0` 은 짝이라
> 하나만 `true` / `false` 로 바꾸면 가는 길과 오는 길이 달라져 NVA 가 세션을 버린다.

**subnet CIDR 규칙**: 세 번째 옥텟을 16 단위(0/16/32/48 …)로 잡는다 (i.e., 각 subnet 이 /20 경계에서 시작).
그래서 쓰는 중에도 각 subnet 을 같은 시작 주소로 /20 까지 in-place 확장할 수 있다. cf. 「수정하면 재생성되는 항목」의 subnet `cidr`.

**NVA**: 만들기, 설정, 다시 만들기는 「NVA (VyOS)」 절을 본다.

**범위 밖**: WAPPLES 인스턴스, IPSec(HQ VPN), Service Connector(syslog → bucket), DNS resolver endpoint.
`DRG_IPSEC_RT` 는 만들어 두었으니 IPSec 연결 후 해당 attachment 에 지정하면 된다.

## 내부 구조 메모 (modules/, stacks/ 를 고칠 사람용)

- **Route table 은 3개 리소스 블록** (`route_tables.tf`). YAML 위치(`locals.tf` 의 `rt_all.kind`)로 나뉜다.
  SGW 가 RT 를 참조하고 그 RT 가 다시 SGW 를 target 으로 쓰면 Terraform 순환 의존으로 plan 이 실패하기 때문이다.
- **subnet ↔ route table 연결은 `oci_core_route_table_attachment`**
  RT 가 같은 VCN 의 private IP(NVA)를 target 으로 쓰면 `subnet → RT → private IP → subnet` 순환이 생겨서,
  subnet 은 기본 RT 로 만든 뒤 연결만 따로 한다.
- SGW 용 RT(DRG target)는 같은 VCN 의 DRG attachment 보다 먼저 만들어진다. OCI 는 attach 되지 않은 DRG 를
  target 으로 받는다 (2026-11 실제 테넌시에서 이 순서 그대로 확인).
- **스키마는 두 곳**: 타입은 `modules/network/variables.tf`, 허용 키 목록은 `modules/config/main.tf` 의 `allowed`.
- spoke 는 hub 의 DRG 를 `external_drg_ids` / `external_drg_route_table_ids` 로 받는다.
  DRG route table 의 `next_hop` 은 hub stack 의 attachment 만 쓸 수 있다.
- **NVA secondary VNIC 은 순번마다 `stacks/30-nva/vnic` module 을 `depends_on` 으로 이어 붙인다** (`vnic_1` → `vnic_2` → `vnic_3`).
  부팅 중에 붙거나 동시에 붙으면 VyOS 의 eth 번호가 섞인다 (2026-11 확인: eth0 = ha VNIC). 그래서 `time_sleep` 으로 부팅(180초)을 기다린 뒤 붙인다.
- **`enabled: auto`**: privateip 조회(`data.oci_core_private_ips.rt_target`)가 비면 그 rule 을 뺀다. 그 IP 를 쓰는 rule 이 모두 auto 일 때만 조회 실패를 오류로 보지 않는다.
- 수정 후에는 `make fmt && make test` 로 확인한다.

> [!IMPORTANT]
> YAML 키를 추가할 때는 `variables.tf` 의 타입과 `modules/config/main.tf` 의 `allowed` 를 **같이** 고친다.
> Terraform 은 타입에 없는 키를 조용히 버리므로, 한쪽만 고치면 오류 없이 값이 무시된다.

> [!NOTE]
> Compartment 는 `enable_delete = false` 라 destroy 해도 OCI 에 남는다. 다시 apply 하면 같은 이름의 compartment 를 자동으로 가져다 쓴다.
