#
# 설정 값끼리의 정합성 검사 (리소스를 만들기 전에 plan 단계에서 걸러냄)
# 결과는 output.config_errors → stack 의 terraform_data.config_check 가 한 번에 출력
#

locals {
  service_keywords = ["all-services", "objectstorage"]
  cmp_names        = keys(var.compartment_ids)
  drg_names        = concat(keys(var.drgs), keys(var.external_drg_ids))

  # inner CIDR 이 outer CIDR 안에 들어가는지:
  #   inner prefix >= outer prefix  그리고  inner 주소를 outer prefix 로 자른 네트워크 == outer 네트워크

  # route table 종류별로 쓸 수 있는 target (OCI 제약)
  #   https://docs.oracle.com/iaas/Content/Network/Tasks/transitrouting.htm
  rt_allowed_targets = {
    subnet = ["igw", "sgw", "drg", "privateip"]
    sgw    = ["drg", "privateip"]
    drga   = ["sgw", "privateip"]
  }
  rt_kind_label = {
    subnet = "subnet 용"
    sgw    = "Service Gateway 용"
    drga   = "DRG attachment(VCN ingress) 용"
  }

  # ── compartment 참조 ───────────────────────────────────────
  compartment_refs = concat(
    [for vk, v in var.vcns : { where = "VCN ${vk}", ref = v.compartment }],
    flatten([
      for vk, v in var.vcns : concat(
        [for k, x in v.internet_gateways : { where = "IGW ${k}", ref = x.compartment } if x.compartment != null],
        [for k, x in v.service_gateways : { where = "SGW ${k}", ref = x.compartment } if x.compartment != null],
        [for k, x in v.subnets : { where = "subnet ${k}", ref = x.compartment } if x.compartment != null]
      )
    ]),
    [for r in local.rt_raw : { where = "route table ${r.key}", ref = r.compartment } if r.compartment != null],
    [for k, o in local.fw_owner : { where = "${o.owner_kind == "sl" ? "security list" : "NSG"} ${k}", ref = o.compartment } if o.compartment != null],
    [for dk, d in var.drgs : { where = "DRG ${dk}", ref = d.compartment }]
  )

  err_compartment = [
    for r in local.compartment_refs : "${r.where}: compartment '${r.ref}' 가 없습니다 (compartments.yaml 과 00-iam apply 확인)"
    if !contains(local.cmp_names, r.ref) && !startswith(r.ref, "ocid1.")
  ]

  # ── 이름 중복 (같은 종류끼리 유일해야 함) ───────────────────
  name_pools = {
    "subnet"              = flatten([for v in var.vcns : keys(v.subnets)])
    "route table"         = [for r in local.rt_raw : r.key]
    "security list / NSG" = flatten([for v in var.vcns : concat(keys(v.security_lists), keys(v.network_security_groups))])
    "gateway"             = flatten([for v in var.vcns : concat(keys(v.internet_gateways), keys(v.service_gateways))])
    "DRG attachment"      = [for v in var.vcns : v.drg_attachment.name if v.drg_attachment != null]
    "DRG route table"     = flatten([for d in var.drgs : keys(d.route_tables)])
  }

  err_duplicate = flatten([
    for kind, names in local.name_pools : [
      for n in distinct(names) : "${kind} 이름 '${n}' 이 중복 정의됨 (이름은 전체에서 유일해야 합니다)"
      if length([for x in names : x if x == n]) > 1
    ]
  ])

  # ── VCN ────────────────────────────────────────────────────
  err_vcn = flatten([
    for vk, v in local.vcn : concat(
      length(v.cidrs) > 0 && alltrue([for c in v.cidrs : can(cidrhost(c, 0))]) ? [] : ["VCN ${vk}: cidrs 형식 오류 (예: [10.0.0.0/16])"],
      v.dns_label == null || can(regex("^[a-z][a-z0-9]{0,14}$", v.dns_label)) ? [] : ["VCN ${vk}: dns_label '${coalesce(v.dns_label, "-")}' 은 영소문자로 시작하는 영소문자·숫자 15자 이내여야 합니다"]
    )
  ])

  # ── Subnet ─────────────────────────────────────────────────
  err_subnet = flatten([
    for sk, s in local.subnet : concat(
      can(cidrhost(s.cidr, 0)) ? [] : ["subnet ${sk}: cidr '${s.cidr}' 형식 오류"],

      anytrue([
        for c in local.vcn[s.vcn_key].cidrs : try(
          tonumber(split("/", s.cidr)[1]) >= tonumber(split("/", c)[1]) &&
          cidrhost("${split("/", s.cidr)[0]}/${split("/", c)[1]}", 0) == cidrhost(c, 0),
          false
        )
      ]) ? [] : ["subnet ${sk}: ${s.cidr} 이 ${s.vcn_key} CIDR(${join(", ", local.vcn[s.vcn_key].cidrs)}) 범위 밖입니다"],

      (
        s.route_table == null ? [] :
        !try(local.rt_all[s.route_table].vcn_key == s.vcn_key, false) ? ["subnet ${sk}: route_table '${s.route_table}' 이 ${s.vcn_key} 에 없습니다"] :
        local.rt_all[s.route_table].kind != "subnet" ? ["subnet ${sk}: route_table '${s.route_table}' 은 ${local.rt_kind_label[local.rt_all[s.route_table].kind]} 이라 subnet 에 쓸 수 없습니다 (route_tables: 아래에 정의)"] :
        []
      ),

      [
        for n in s.security_lists : "subnet ${sk}: security list '${n}' 이 ${s.vcn_key} 에 없습니다"
        if n != "default" && !try(local.sl[n].vcn_key == s.vcn_key, false)
      ],

      s.dns_label == null || can(regex("^[a-z][a-z0-9]{0,14}$", s.dns_label)) ? [] : ["subnet ${sk}: dns_label '${coalesce(s.dns_label, "-")}' 은 영소문자로 시작하는 영소문자·숫자 15자 이내여야 합니다"],

      s.dns_label == null || local.vcn[s.vcn_key].dns_label != null ? [] : ["subnet ${sk}: dns_label 을 쓰려면 ${s.vcn_key} 에도 dns_label 이 있어야 합니다"]
    )
  ])

  # ── Route rule ─────────────────────────────────────────────
  rt_rules_flat = flatten([
    for rk, r in local.rt_all : [
      for rule in r.rules : {
        rt_key      = rk
        rt_kind     = r.kind
        vcn_key     = r.vcn_key
        destination = rule.destination
        target      = rule.target
        kind        = split(":", rule.target)[0]
        name        = try(split(":", rule.target)[1], "")
      }
    ]
  ])

  err_route_rule = flatten([
    for r in local.rt_rules_flat : concat(
      contains(local.service_keywords, r.destination) || can(cidrhost(r.destination, 0)) ? [] : [
        "route table ${r.rt_key}: destination '${r.destination}' 형식 오류 (CIDR 또는 all-services / objectstorage)"
      ],

      (
        startswith(r.target, "ocid1.") ? [] :
        !contains(local.rt_allowed_targets[r.rt_kind], r.kind) ? (
          contains(["igw", "sgw", "drg", "privateip"], r.kind)
          ? ["route table ${r.rt_key}: ${local.rt_kind_label[r.rt_kind]} route table 은 ${join(" / ", [for k in local.rt_allowed_targets[r.rt_kind] : "${k}:"])} 만 target 으로 쓸 수 있습니다 (${r.target})"]
          : ["route table ${r.rt_key}: target '${r.target}' 형식 오류 (igw:/sgw:/drg:/privateip:/ocid1.)"]
        ) :
        r.kind == "igw" ? (try(local.igw[r.name].vcn_key == r.vcn_key, false) ? [] : ["route table ${r.rt_key}: ${r.target} 이 같은 VCN(${r.vcn_key}) 에 없습니다"]) :
        r.kind == "sgw" ? (try(local.sgw[r.name].vcn_key == r.vcn_key, false) ? [] : ["route table ${r.rt_key}: ${r.target} 이 같은 VCN(${r.vcn_key}) 에 없습니다"]) :
        r.kind == "drg" ? (r.name == local.vcn[r.vcn_key].drg_key ? [] : ["route table ${r.rt_key}: ${r.vcn_key} 는 DRG '${r.name}' 에 attach 되어 있지 않습니다 (drg_attachment 확인)"]) :
        (try(local.pip["${r.name}@${r.vcn_key}"].subnet_key != null, false) ? [] : ["route table ${r.rt_key}: ${r.name} 이 들어가는 subnet 이 ${r.vcn_key} 에 없습니다"])
      ),

      r.kind == "drg" && anytrue([
        for c in local.vcn[r.vcn_key].cidrs : try(
          tonumber(split("/", r.destination)[1]) >= tonumber(split("/", c)[1]) &&
          cidrhost("${split("/", r.destination)[0]}/${split("/", c)[1]}", 0) == cidrhost(c, 0),
          false
        )
      ]) ? ["route table ${r.rt_key}: 목적지 ${r.destination} 는 자기 VCN(${r.vcn_key}) CIDR 안이라 DRG 로 보낼 수 없습니다"] : []
    )
  ])

  err_route_dup_dest = flatten([
    for rk, r in local.rt_all : [
      for d in distinct([for x in r.rules : x.destination]) : "route table ${rk}: destination ${d} 가 두 번 이상 나옵니다"
      if length([for x in r.rules : x if x.destination == d]) > 1
    ]
  ])

  # ── Service Gateway ────────────────────────────────────────
  err_sgw = [
    for gk, g in local.sgw : "SGW ${gk}: services 는 all-services 또는 objectstorage"
    if !contains(local.service_keywords, g.services)
  ]

  # ── DRG attachment ─────────────────────────────────────────
  err_drga = flatten([
    for ak, a in local.drga : concat(
      contains(local.drg_names, a.drg_key) ? [] : ["DRG attachment ${ak}: DRG '${a.drg_key}' 가 없습니다 (drg.yaml 과 10-hub apply 확인)"],
      (
        a.drg_route_table == null ||
        try(local.drg_rt[a.drg_route_table].drg_key == a.drg_key, false) ||
        contains(keys(var.external_drg_route_table_ids), a.drg_route_table)
      ) ? [] : ["DRG attachment ${ak}: drg_route_table '${coalesce(a.drg_route_table, "-")}' 이 ${a.drg_key} 에 없습니다 (DRG 기본 테이블은 autogenerated)"]
    )
  ])

  # ── DRG route rule ─────────────────────────────────────────
  err_drg_rule = flatten([
    for k, r in local.drg_rt_rules : concat(
      can(cidrhost(r.destination, 0)) ? [] : ["DRG route table ${r.rt_key}: destination '${r.destination}' 형식 오류"],
      try(local.drga[r.next_hop].drg_key == r.drg_key, false) ? [] : ["DRG route table ${r.rt_key}: next_hop '${r.next_hop}' 은 ${r.drg_key} 의 attachment 가 아닙니다 (hub stack 의 attachment 만 가능)"]
    )
  ])

  # ── Security list / NSG rule ───────────────────────────────
  err_fw = flatten([
    for r in local.fw_rules : concat(
      (
        startswith(coalesce(r.cidr, "-"), "nsg:") ? (
          r.owner_kind != "nsg" ? ["${r.where}: nsg: 는 NSG 규칙에서만 쓸 수 있습니다 (Security List 는 CIDR 만)"] :
          try(local.nsg[trimprefix(r.cidr, "nsg:")].vcn_key == local.fw_owner[r.owner].vcn_key, false) ? [] :
          ["${r.where}: ${r.cidr} 이 같은 VCN(${local.fw_owner[r.owner].vcn_key}) 에 없습니다 (NSG 끼리는 같은 VCN 만 가능)"]
        ) :
        contains(local.service_keywords, r.cidr) || can(cidrhost(r.cidr, 0)) ? [] : ["${r.where}: '${coalesce(r.cidr, "-")}' 형식 오류 (CIDR, all-services, objectstorage${r.owner_kind == "nsg" ? ", nsg:<이름>" : ""})"]
      ),
      contains(["all", "tcp", "udp", "icmp"], r.kind) ? [] : ["${r.where}: protocol 은 all / tcp / udp / icmp"],
      r.port == null || (contains(["tcp", "udp"], r.kind) && r.port_min != null && r.port_max != null) ? [] : ["${r.where}: port 는 tcp/udp 에서만, 형식 '443' 또는 '8000-8080'"],
      r.sport == null || (contains(["tcp", "udp"], r.kind) && r.sport_min != null && r.sport_max != null) ? [] : ["${r.where}: source_port 는 tcp/udp 에서만, 형식 '53' 또는 '1024-65535'"]
    )
  ])

  config_errors = concat(
    local.err_compartment,
    local.err_duplicate,
    local.err_vcn,
    local.err_subnet,
    local.err_route_rule,
    local.err_route_dup_dest,
    local.err_sgw,
    local.err_drga,
    local.err_drg_rule,
    local.err_fw
  )
}
