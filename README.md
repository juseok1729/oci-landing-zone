# OCI Hub & Spoke Landing Zone (YAML-driven Terraform)

![Terraform](https://img.shields.io/badge/Terraform-~%3E%201.12-844FBA?logo=terraform&logoColor=white)
![oracle/oci](https://img.shields.io/badge/oracle%2Foci-9.13.0-C74634?logo=oracle&logoColor=white)
![hashicorp/time](https://img.shields.io/badge/hashicorp%2Ftime-0.14.2-844FBA?logo=hashicorp&logoColor=white)
![OCI backend](https://img.shields.io/badge/state-OCI%20Object%20Storage-C74634?logo=oracle&logoColor=white)

**YAML 이 설계서이고, Terraform 은 그 YAML 을 읽어 리소스로 바꾸는 범용 엔진이다.**
실제 값(CIDR, 이름, 규칙)은 전부 `config/` 에 있고, `.tf` 코드는 YAML 을 읽어 `for_each` 로 리소스를 만드는 역할만 한다.
그래서 설계서의 HUB / PRD / DEV / MGMT 구조를 **YAML 만 고쳐서** 운영한다.

> [!IMPORTANT]
> 팀원은 `config/` 아래 YAML 만 수정한다. `modules/` · `stacks/` 는 관리자(owner)만 손댄다.

```
oci-hub-spoke-lz/
├── config/                 ← 일상 변경은 여기만
│   ├── compartments.yaml
│   ├── drg.yaml            DRG, DRG route table
│   ├── buckets.yaml
│   └── vcns/
│       ├── hub.yaml        VCN 1개 = 파일 1개 = stack 1개
│       ├── prd.yaml
│       ├── dev.yaml
│       └── mgmt.yaml
├── stacks/                 state 를 나눈 실행 단위 (얇은 루트 모듈)
│   ├── 00-iam/             compartment            (홈 리전)        state: lz/iam.tfstate
│   ├── 10-hub/             DRG · HUB_VCN · bucket                  state: lz/hub.tfstate
│   └── 20-spoke/           spoke VCN · bucket     (workspace 별)   state: tf-state-env/<prd|dev|mgmt>/lz/spoke.tfstate
├── modules/
│   ├── config/             YAML 읽기 + 알 수 없는 키(오타) 검사
│   ├── compartments/
│   ├── network/            VCN, Gateway, DRG, Route table, Security list, NSG, Subnet
│   └── buckets/
├── tests/fixtures/         테스트용 YAML
└── Makefile
```

## 빠른 시작

> [!IMPORTANT]
> state 버킷은 Terraform 이 만들지 않는다. **Versioning 을 켠 버킷을 먼저 만들고** 시작한다.
> `backend.hcl` 에는 `key` 를 넣지 않는다 (i.e., stack 마다 `main.tf` 에 고정돼 있다).

```bash
cp terraform.tfvars.example terraform.tfvars   # tenancy_ocid, region, profile, state_bucket/namespace
cp backend.hcl.example backend.hcl             # state 버킷 (미리 생성 + Versioning). key 는 넣지 않음

make init
make apply-iam        # 1. compartment
make apply-hub        # 2. DRG, HUB_VCN
make apply-prd        # 3. spoke (dev, mgmt 도 같은 방식)
# 또는 make apply-all  (iam → hub → prd → dev → mgmt 순서)
# 삭제: make destroy-all (역순. compartment 는 state 에서만 빠지고 OCI 에 남음. cf. enable_delete = false)
```

> [!TIP]
> `make apply-*` 는 plan 을 먼저 보여 주고 `yes` 를 기다린다. 따로 `make plan-*` 을 돌릴 필요는 없다.
> 바꾸지 않고 변경 내용만 보고 싶을 때 `make plan-*` 을 쓴다.

> [!WARNING]
> stack 은 **iam → hub → spoke** 순서로 apply 한다. 뒤 stack 은 앞 stack 의 state(output)를 읽으므로,
> 앞 stack 을 apply 하기 전에는 뒤 stack 의 plan 이 실패한다. 삭제는 반대 순서(spoke → hub → iam)다.

- Terraform **1.12 이상** (native `oci` backend). provider 버전은 각 stack 의 `.terraform.lock.hcl` 로 고정 (oracle/oci 9.x)
- 의존 방향은 **iam → hub → spoke** 하나뿐이다. 뒤 stack 은 앞 stack 의 output 을 `terraform_remote_state` 로 읽는다
  - hub, spoke ← iam: `compartment_ids`
  - spoke ← hub: `drg_ids`, `drg_route_table_ids`
- spoke 는 `stacks/20-spoke` 하나를 **workspace 로 나눠** 쓴다. workspace 이름 = `config/vcns/<이름>.yaml`.
  Makefile 이 `workspace select` 를 대신 한다. 직접 실행하는 명령어는 아래와 같다.
  ```bash
  cd stacks/20-spoke && terraform workspace select -or-create prd && terraform plan -var-file=../../terraform.tfvars
  ```
- 새 spoke VCN 은 `config/vcns/<이름>.yaml` 을 추가하고 `make apply-<이름>` (Makefile 의 `SPOKES` 에도 추가)
- Compartment(IAM)는 홈 리전에서만 생성된다. 리소스 리전과 홈 리전이 다르면 `home_region` 지정
- 모든 리소스에 `ManagedBy=terraform`, `Stack=<iam|hub|prd|...>` freeform tag 가 붙는다.

> [!CAUTION]
> `ManagedBy=terraform` 태그가 붙은 리소스를 **콘솔에서 직접 고치지 않는다.** 다음 apply 때 YAML 내용으로 되돌아간다.

### 자격증명 없이 테스트

```bash
make test        # 세 stack 각각 terraform init -backend=false && terraform test
```

| stack | 확인하는 것 |
|---|---|
| 00-iam | compartment 4개 |
| 10-hub | 실제 `hub.yaml` apply 그래프 (subnet 6, RT 7, DRG 1, attachment 1, SL 4, NSG 2), privateip target · NSG · source_port, 게이트웨이 RT 제약 위반 거부 |
| 20-spoke | prd · dev · mgmt apply (subnet · RT · attachment · bucket · NSG 개수), hub 파일 선택 거부, 잘못된 YAML(`tests/fixtures/broken`) 거부 |

다른 stack 의 state 는 테스트에서 `override_data` 로 대신한다.

> [!NOTE]
> `make test` 는 OCI 에 연결하지 않고(mock provider), 선택된 workspace 와 상관없이 `default` workspace 로 돈다.
> config 를 고친 뒤 apply 전에 돌리면 YAML 오류와 리소스 개수 변화를 먼저 잡을 수 있다.

## 예제 (자주 하는 작업)

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
        - destinations: [10.1.0.0/16, 10.2.0.0/16, 10.3.0.0/16] # 대상 여러 개 → destinations (같은 target)
          target: drg:HUB_DRG
          description: "spoke VCN"
        - destination: all-services                             # OCI 서비스 전체(OSN) → SGW. SGW services 와 같아야 함
          target: sgw:HUB_SGW
        - destination: 0.0.0.0/0                                # FortiGate VIP 로 (IP 가 실제로 있어야 plan 통과)
          target: privateip:10.0.16.160
          enabled: false                                        # 끄기 (i.e., 지우지 않고 보관)
    HUB_EDGE_PUB_RT:
      rules:
        - destination: 0.0.0.0/0
          target: igw:HUB_IGW
```

> [!IMPORTANT]
> `privateip:` target 은 그 IP 가 **실제로 있어야** plan 이 통과한다. FortiGate 같은 대상을 배포하기 전에는 `enabled: false` 로 두고,
> 배포 후 `true` 로 바꿔 다시 apply 한다. 대상 VNIC 에는 **Skip source/destination check** 가 켜져 있어야 트래픽이 지나간다.

### Gateway 와 gateway 용 route table (hub)

```yaml
  internet_gateways:
    HUB_IGW: {}                               # enabled: false 로 두면 IGW 는 남기고 트래픽만 차단

  service_gateways:
    HUB_SGW:
      services: all-services                  # 또는 objectstorage
      route_table:                            # SGW 로 들어온 응답이 갈 곳. target 은 drg: / privateip: 만
        name: HUB_SGW_RT
        rules:
          - destinations: [10.1.0.0/16, 10.2.0.0/16, 10.3.0.0/16]
            target: drg:HUB_DRG

  drg_attachment:
    name: HUB_DRG_ATT
    drg: HUB_DRG
    drg_route_table: autogenerated            # DRG 쪽 테이블 (drg.yaml 의 이름 또는 autogenerated)
    route_table:                              # DRG → VCN 으로 들어올 때. target 은 sgw: / privateip: 만
      name: HUB_INGRESS_RT
      rules:
        - destination: all-services
          target: sgw:HUB_SGW
        - destinations: [10.1.0.0/16, 10.2.0.0/16]
          target: privateip:10.0.16.160
          enabled: false
```

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

### DRG route table (`config/drg.yaml`) 과 spoke attachment

```yaml
# config/drg.yaml
drgs:
  HUB_DRG:
    compartment: HUB_COMP
    route_tables:
      DRG_SPOKE_RT:
        rules:
          - destination: 0.0.0.0/0
            next_hop: HUB_DRG_ATT             # DRG attachment 이름 (hub stack 의 attachment 만)
      DRG_IPSEC_RT:
        rules:
          - destinations: [10.0.0.0/16, 10.1.0.0/16, 10.2.0.0/16, 10.3.0.0/16]
            next_hop: HUB_DRG_ATT
```

```yaml
# config/vcns/prd.yaml
  drg_attachment:
    name: PRD_DRG_ATT
    drg: HUB_DRG                              # hub stack 이 만든 DRG
    drg_route_table: DRG_SPOKE_RT
```

### 새 spoke VCN

`config/vcns/stg.yaml` 을 만들고 Makefile 의 `SPOKES` 에 `stg` 를 추가한 뒤 `make apply-stg`.

```yaml
STG_VCN:
  compartment: STG_COMP                       # compartments.yaml 에도 추가 → make apply-iam 먼저
  cidrs: [10.4.0.0/16]
  dns_label: stg

  drg_attachment:
    name: STG_DRG_ATT
    drg: HUB_DRG
    drg_route_table: DRG_SPOKE_RT

  route_tables:
    STG_RT:
      rules:
        - destination: 0.0.0.0/0
          target: drg:HUB_DRG

  subnets:
    STG_APP_PRI_SBN:
      cidr: 10.4.0.0/24
      route_table: STG_RT
      dns_label: app
```

> [!IMPORTANT]
> 새 spoke 의 대역(`10.4.0.0/16`)을 hub 쪽 `HUB_SGW_RT`, `HUB_FW_TRUST_PRI_RT`, `DRG_IPSEC_RT` 의 spoke 대역 목록에도 추가해야
> 응답이 돌아온다. hub 를 먼저 `make apply-hub` 한 뒤 `make apply-stg` 한다.

### Compartment / bucket

```yaml
# config/compartments.yaml
compartments:
  STG_COMP:
    description: "스테이징"
  SHARED_COMP:
    ocid: ocid1.compartment.oc1..aaaa...      # 이미 있는 compartment (i.e., 만들지 않고 참조만)
```

```yaml
# config/buckets.yaml: compartment 가 spoke 의 것이면 그 spoke stack, 아니면 hub stack 이 만든다
buckets:
  STG-APP-LOG-01:
    compartment: STG_COMP
  MGMT-ARCHIVE-01:
    compartment: MGMT_COMP
    storage_tier: Archive                     # Standard | Archive
    versioning: true
```

## 수정하면 재생성되는 항목

> [!CAUTION]
> `yes` 를 치기 전에 plan 마지막 줄 `Plan: X to add, Y to change, Z to destroy` 의 **destroy 가 0 인지** 확인한다.
> 0 이 아니면 멈추고 `-/+` / `must be replaced` 가 붙은 리소스를 찾는다. 원인은 대부분 아래 표에 있다.

| YAML 에서 바꾸는 것 | 결과 | 영향 |
|---|---|---|
| subnet `public` | **삭제 → 재생성** | subnet 안에 VNIC(인스턴스, LB …)가 있으면 삭제가 실패 |
| subnet `dns_label` | **삭제 → 재생성** | 위와 같음 |
| VCN `dns_label` | **삭제 → 재생성** | VCN 아래 subnet · RT · gateway 전부 |
| YAML **키 이름** (subnet · RT · SL · NSG · gateway · bucket) | **삭제 → 재생성** | Terraform 은 키 이름으로 리소스를 구분하므로 이름을 바꾸면 다른 리소스 |
| compartment 키 이름 | 새로 생성 + 기존 것은 state 에서만 빠짐 | `enable_delete = false` 라서 기존 compartment 는 OCI 에 남음 |

제자리 수정(`~ update in-place`) 되는 것:

- route rule 추가 · 삭제 · `enabled`, SL / NSG 규칙, `display_name`, subnet 의 `route_table` · `security_lists`
- VCN `cidrs` 에 대역 추가
- subnet `cidr`: 시작 주소가 같아야 함 (e.g., `10.0.80.0/24` → `/23` 처럼 크기만). 쓰고 있는 IP 도 새 범위 안에 있어야 함
- NSG 규칙을 목록 **중간에** 끼우면 뒤 규칙들이 순번 키(`<NSG>|ingress|<i>`)가 밀려 줄줄이 update 된다

> [!TIP]
> NSG 규칙은 목록 **끝에 추가**하면 plan 이 새 규칙 1개 생성으로 끝난다.

근거: oracle/oci provider 의 `ForceNew` 필드 (`core_subnet_resource.go`, `core_vcn_resource.go`).
SGW · IGW · DRG attachment · bucket 의 재생성 조건은 여기 정리하지 않았으니 plan 의 `-/+` 로 판단한다.

## YAML 표기법

**route table 은 붙는 곳에 적는다.** 적힌 위치가 곧 종류이고, 종류마다 쓸 수 있는 target 이 다르다 (OCI 제약).

| 위치 | 종류 | 쓸 수 있는 target |
|---|---|---|
| `route_tables:` | subnet 용 | `igw:` `sgw:` `drg:` `privateip:` |
| `service_gateways.<SGW>.route_table:` (`name`, `rules`) | Service Gateway 용 | `drg:` `privateip:` |
| `drg_attachment.route_table:` (`name`, `rules`) | DRG attachment(VCN ingress) 용 | `sgw:` `privateip:` |

게이트웨이용 RT 를 subnet 에 쓰거나, 허용되지 않은 target 을 쓰면 plan 단계에서 막힌다.
RT 를 다른 위치로 옮기면 Terraform 주소가 바뀌어 **삭제 후 재생성**된다 (YAML diff 에 그대로 드러난다).

**route rule target**

| 표기 | 의미 |
|---|---|
| `igw:HUB_IGW` | 같은 VCN 의 Internet Gateway |
| `sgw:HUB_SGW` | 같은 VCN 의 Service Gateway |
| `drg:HUB_DRG` | 이 VCN 이 attach 된 DRG |
| `privateip:10.0.16.160` | 같은 VCN 안의 Private IP (FortiGate VIP 등). IP 가 실제로 있어야 함 |
| `ocid1....` | OCID 직접 지정 (검사하지 않음) |

**destination**: CIDR, `all-services`(All ICN Services In OSN), `objectstorage`. 여러 개는 `destinations: [a, b]`

**SL / NSG 규칙**: `source`(ingress) / `destination`(egress) 은 CIDR 또는 `all-services` / `objectstorage`.
NSG 규칙은 `nsg:<이름>` 으로 **같은 VCN 의** 다른 NSG(또는 자기 자신)도 지정할 수 있다 (Security List 는 불가).
`protocol`: all / tcp / udp / icmp. `port` = 목적지 포트, `source_port` = 출발지 포트 (`"53"` 또는 `"1024-65535"`, tcp/udp 만).

**이름 규칙**: YAML 키가 곧 OCI 표시 이름이자 Terraform 식별자다.

> [!WARNING]
> YAML 키(리소스 이름)를 바꾸면 **삭제 후 재생성**된다. 표시 이름만 바꾸려면 키는 두고 `display_name:` 을 쓴다.

**기본값**

| 항목 | 생략 시 |
|---|---|
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

**bucket 은 compartment 로 stack 이 정해진다**: spoke VCN 의 compartment 에 속한 bucket 은 그 spoke stack,
나머지는 hub stack 이 만든다.

모든 필드는 `modules/network/variables.tf` 의 타입 정의가 곧 스키마다.

## 검증 (plan 단계)

YAML 이 잘못되면 리소스를 만들기 전에 한 번에 목록으로 보여주고 멈춘다. 각 stack 은 자기와 관련된 파일만 검사한다.

```
Error: Resource precondition failed
config/ YAML 오류 4건
  - vcns/prd.yaml > PRD_VCN.subnets.PRD_WEB_PRI_SBN: 알 수 없는 키 'route_tabel'
  - VCN PRD_VCN: compartment 'PRD_COMPP' 가 없습니다 (compartments.yaml 과 00-iam apply 확인)
  - subnet PRD_WEB_PRI_SBN: 10.2.10.0/24 이 PRD_VCN CIDR(10.1.0.0/16) 범위 밖입니다
  - route table HUB_SGW_RT: Service Gateway 용 route table 은 drg: / privateip: 만 target 으로 쓸 수 있습니다 (igw:HUB_IGW)
```

검사 항목: 알 수 없는 키(오타), compartment·route table·security list·NSG·gateway·DRG 참조,
게이트웨이 RT 의 target 제약, subnet CIDR 범위, 자기 VCN CIDR 를 DRG 로 보내는 rule, destination 중복,
dns_label 형식, 이름 중복(attachment 포함), 포트 형식, DRG next_hop, VCN 파일당 1개.

> [!NOTE]
> 검사하지 않는 것: subnet 끼리 CIDR 겹침(apply 에서 OCI 가 거부), OCID 로 직접 쓴 target,
> route rule destination 과 SGW `services` 의 일치 여부(apply 에서 OCI 가 거부).

## 설계서 대비 변경 · 확인 필요

**수정한 것** (설명과 CIDR 가 맞지 않아 설명 기준으로 맞춤, YAML 에 `[설계서 수정]` 주석)

| 위치 | 설계서 | 반영 |
|---|---|---|
| PRD_PRI_RT "관리 VCN" | 10.1.0.0/16 (PRD 자기 CIDR) | 10.3.0.0/16 |
| DEV_PRI_RT "관리 VCN" | 10.1.0.0/16 (운영 VCN) | 10.3.0.0/16 |
| MGMT_PRI_RT "운영 VCN" | 10.3.0.0/16 (MGMT 자기 CIDR) | 10.1.0.0/16 |
| HUB subnet 의 RT 이름 | `FW_*_RT` | `HUB_FW_*_RT` (route table 표 이름에 맞춤) |
| subnet CIDR | 1/10/20/30… | 0/16/32/48… (/20 경계 정렬 → 각 subnet 을 in-place 로 /20 까지 확장 가능) |

**확인 필요** (YAML 에 `enabled: false` 또는 `[확인 필요]` 로 표시)

1. **spoke 의 인터넷/OSN 경로가 없음**: DRG_SPOKE_RT 가 0.0.0.0/0 → HUB 인데, spoke RT 에 0.0.0.0/0 → DRG 가 없어서
   HUB_INGRESS_RT 의 OSN 경로와 HUB_SGW_RT 가 실제로 쓰이지 않는다. 각 spoke RT 에 `enabled: false` 로 넣어 둠
2. **HUB_INGRESS_RT 에 FortiGate 경로가 없음**: spoke→인터넷, spoke↔spoke(PRD↔MGMT) 트래픽이 HUB 에서 버려진다.
   `privateip:10.0.16.160` 으로 보내는 rule 을 `enabled: false` 로 넣어 둠
3. **HUB_FW_WAF_PRI_RT 의 FortiGate port3 rule**: FortiGate 배포 전에는 private IP 가 없어 조회가 실패하므로
   `enabled: false` 로 시작. FortiGate 배포 후 `true` 로 바꾸고 다시 apply
4. **MGMT_BASTION_PUB_SBN**: 이름은 PUB 인데 MGMT_VCN 에 IGW 가 없음. OCI Bastion 서비스용이면 private 으로 충분
5. **Security List**: 설계서에 없어 대부분의 subnet 이 VCN Default Security List(SSH 22 전체 허용 포함)를 쓴다.
   `security_lists` 를 정의하거나 VCN 에 `lock_default_security_list: true` 로 기본 규칙을 비울 수 있다

**범위 밖**: FortiGate/WAPPLES 인스턴스, IPSec(HQ VPN), Service Connector(syslog → bucket), DNS resolver endpoint.
`DRG_IPSEC_RT` 는 만들어 두었으니 IPSec 연결 후 해당 attachment 에 지정하면 된다.

## 내부 구조 메모 (modules/ · stacks/ 를 고칠 사람용)

- **Route table 은 3개 리소스 블록** (`route_tables.tf`). YAML 위치(`locals.tf` 의 `rt_all.kind`)로 나뉜다.
  SGW 가 RT 를 참조하고 그 RT 가 다시 SGW 를 target 으로 쓰면 Terraform 순환 의존으로 plan 이 실패하기 때문이다.
- **subnet ↔ route table 연결은 `oci_core_route_table_attachment`**
  RT 가 같은 VCN 의 private IP(FortiGate)를 target 으로 쓰면 `subnet → RT → private IP → subnet` 순환이 생겨서,
  subnet 은 기본 RT 로 만든 뒤 연결만 따로 한다.
- HUB_SGW_RT(DRG target)는 hub DRG attachment 보다 먼저 만들어진다. OCI 는 attach 되지 않은 DRG 를
  target 으로 받는다 (2026-11 실제 테넌시에서 이 순서 그대로 확인).
- **스키마는 두 곳**: 타입은 `modules/network/variables.tf`, 허용 키 목록은 `modules/config/main.tf` 의 `allowed`.
- spoke 는 hub 의 DRG 를 `external_drg_ids` / `external_drg_route_table_ids` 로 받는다.
  DRG route table 의 `next_hop` 은 hub stack 의 attachment 만 쓸 수 있다.
- 수정 후에는 `make fmt && make test` 로 확인한다.

> [!IMPORTANT]
> YAML 키를 추가할 때는 `variables.tf` 의 타입과 `modules/config/main.tf` 의 `allowed` 를 **같이** 고친다.
> Terraform 은 타입에 없는 키를 조용히 버리므로, 한쪽만 고치면 오류 없이 값이 무시된다.

> [!NOTE]
> Compartment 는 `enable_delete = false` 라 destroy 해도 OCI 에 남는다. 다시 apply 하면 같은 이름의 compartment 를 자동으로 가져다 쓴다.
