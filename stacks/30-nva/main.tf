#
# 30-nva : NVA 인스턴스(config/nvas.yaml) + secondary VNIC · secondary IP · reserved public IP
#   hub 의 subnet 에 붙으므로 hub 다음에 apply 하고, hub 보다 먼저 destroy 한다.
#
terraform {
  required_version = "~> 1.12"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }

  # bucket / namespace / region 은 backend.hcl 로 주입 (key 는 여기 고정. N.B. backend.hcl 에 key 를 넣지 않는다)
  backend "oci" {
    key = "lz/nva.tfstate"
  }
}

provider "oci" {
  region              = var.region
  auth                = var.oci_auth
  config_file_profile = var.oci_config_profile
}

locals {
  # terraform_remote_state 의 oci backend 는 auth 값을 APIKey 로 씀 (provider 는 ApiKey)
  state_config = {
    bucket              = var.state_bucket
    namespace           = var.state_namespace
    region              = coalesce(var.state_region, var.region)
    auth                = var.oci_auth == "ApiKey" ? "APIKey" : var.oci_auth
    config_file_profile = var.oci_config_profile
  }
}

data "terraform_remote_state" "iam" {
  backend = "oci"
  config  = merge(local.state_config, { key = "lz/iam.tfstate" })
}

data "terraform_remote_state" "hub" {
  backend = "oci"
  config  = merge(local.state_config, { key = "lz/hub.tfstate" })
}

module "config" {
  source     = "../../modules/config"
  config_dir = var.config_dir
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

locals {
  # 앞 stack(iam, hub) 이 비어 있으면 Unsupported attribute 로 죽지 않고 config_check 의 안내 메시지로 멈춘다
  iam_ready       = can(data.terraform_remote_state.iam.outputs.compartment_ids)
  hub_ready       = can(data.terraform_remote_state.hub.outputs.subnet_ids)
  compartment_ids = try(data.terraform_remote_state.iam.outputs.compartment_ids, {})
  subnet_ids      = try(data.terraform_remote_state.hub.outputs.subnet_ids, {})

  nvas_all = coalesce(module.config.nvas, {})
  # 오류가 하나라도 있으면 아무것도 계획하지 않는다 (없는 키 참조로 죽지 않고 config_check 가 목록으로 보여준다)
  nvas = length(local.config_errors) == 0 ? local.nvas_all : {}

  # "<NVA>|<vnic name>" → vnic.  첫 번째가 primary VNIC
  vnics = merge([
    for n, v in local.nvas : {
      for i, x in try(v.vnics, []) : "${n}|${x.name}" => {
        nva                    = n
        name                   = x.name
        index                  = i
        primary                = i == 0
        subnet                 = x.subnet
        private_ip             = try(x.private_ip, null)
        secondary_ips          = try(x.secondary_ips, [])
        skip_source_dest_check = try(x.skip_source_dest_check, false)
        public_ip              = try(x.public_ip, null)
      }
    }
  ]...)
  primary   = { for k, x in local.vnics : x.nva => x if x.primary }
  secondary = { for k, x in local.vnics : k => x if !x.primary }

  tags = { ManagedBy = "terraform", Stack = "nva" }
}

resource "oci_core_instance" "this" {
  for_each = local.nvas

  compartment_id      = local.compartment_ids[each.value.compartment]
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[try(each.value.availability_domain, 1) - 1].name
  display_name        = try(each.value.display_name, each.key)
  shape               = each.value.shape
  freeform_tags       = local.tags

  shape_config {
    ocpus         = each.value.ocpus
    memory_in_gbs = each.value.memory_gb
  }

  source_details {
    source_type = "image"
    source_id   = each.value.image
  }

  # SSH 키(metadata.ssh_authorized_keys)는 넣지 않는다: 이미지가 비밀번호 인증으로 구성돼 있다
  create_vnic_details {
    subnet_id              = local.subnet_ids[local.primary[each.key].subnet]
    private_ip             = local.primary[each.key].private_ip
    assign_public_ip       = local.primary[each.key].public_ip == "ephemeral"
    skip_source_dest_check = local.primary[each.key].skip_source_dest_check
    display_name           = "${each.key}-${local.primary[each.key].name}"
    freeform_tags          = local.tags
  }
}

# OS 부팅이 끝난 뒤에 secondary VNIC 을 붙인다. 부팅 중에 붙으면 장치가 잡히는 순서가 섞여
# primary 가 eth0 이 되지 않는다 (2026-11 VyOS 에서 eth0 = ha VNIC 으로 확인). 부팅 후에 붙이면 primary 는 eth0,
# 나머지는 붙는 순서대로 eth1, eth2, … 가 된다.
# shortcut: 부팅 완료를 확인하지 않고 시간으로 기다린다, 부팅이 더 길어지면 늘린다
resource "time_sleep" "boot" {
  for_each = oci_core_instance.this

  create_duration = "180s"
  triggers        = { instance = each.value.id }
}

# secondary VNIC 은 YAML 순서대로 하나씩 붙인다 (동시에 붙이면 eth 번호 순서가 매번 달라진다).
# shortcut: secondary VNIC 은 NVA 당 3개까지 (vnic_1~3), 더 필요하면 module 을 하나 더 잇는다
locals {
  vnic_pos = {
    for p in [1, 2, 3] : p => {
      for k, x in local.secondary : k => merge(x, {
        instance_id = oci_core_instance.this[x.nva].id
        subnet_id   = local.subnet_ids[x.subnet]
      }) if x.index == p
    }
  }
}

module "vnic_1" {
  source     = "./vnic"
  vnics      = local.vnic_pos[1]
  tags       = local.tags
  depends_on = [time_sleep.boot]
}

module "vnic_2" {
  source     = "./vnic"
  vnics      = local.vnic_pos[2]
  tags       = local.tags
  depends_on = [module.vnic_1]
}

module "vnic_3" {
  source     = "./vnic"
  vnics      = local.vnic_pos[3]
  tags       = local.tags
  depends_on = [module.vnic_2]
}

locals {
  attachments = merge(module.vnic_1.attachments, module.vnic_2.attachments, module.vnic_3.attachments)
}

data "oci_core_vnic" "secondary" {
  for_each = local.attachments
  vnic_id  = each.value.vnic_id
}

# primary VNIC 의 MAC (eth0 확인용): primary private IP → VNIC
data "oci_core_private_ips" "primary" {
  for_each = local.primary

  ip_address = oci_core_instance.this[each.key].private_ip
  subnet_id  = local.subnet_ids[each.value.subnet]
}

data "oci_core_vnic" "primary" {
  for_each = data.oci_core_private_ips.primary
  vnic_id  = one(each.value.private_ips[*].vnic_id)
}

resource "oci_core_private_ip" "secondary" {
  for_each = merge([
    for k, x in local.secondary : { for ip in x.secondary_ips : "${k}|${ip}" => { vnic = k, ip = ip } }
  ]...)

  vnic_id       = local.attachments[each.value.vnic].vnic_id
  ip_address    = each.value.ip
  display_name  = replace(each.key, "|", "-")
  freeform_tags = local.tags
}

locals {
  # VNIC 의 primary private IP (reserved public IP 를 붙일 대상)
  vnic_ips = merge(
    { for k, x in local.vnics : k => oci_core_instance.this[x.nva].private_ip if x.primary },
    { for k, d in data.oci_core_vnic.secondary : k => d.private_ip_address }
  )
}

data "oci_core_private_ips" "reserved" {
  for_each = { for k, x in local.vnics : k => x if x.public_ip == "reserved" }

  ip_address = local.vnic_ips[each.key]
  subnet_id  = local.subnet_ids[each.value.subnet]
}

resource "oci_core_public_ip" "reserved" {
  for_each = data.oci_core_private_ips.reserved

  compartment_id = local.compartment_ids[local.nvas[local.vnics[each.key].nva].compartment]
  lifetime       = "RESERVED"
  display_name   = "${replace(each.key, "|", "-")}-pip"
  private_ip_id  = one(each.value.private_ips[*].id)
  freeform_tags  = local.tags
}

# VyOS 설정 템플릿 값 (vyos.sh.tftpl)
locals {
  hub_subnets = try(values(module.config.vcn_files["hub"])[0].subnets, {})
  spoke_files = { for f, d in module.config.vcn_files : f => flatten([for v in values(d) : try(v.cidrs, [])]) if f != "hub" }
  spoke_cidrs = sort(flatten(values(local.spoke_files)))
  prd_cidrs   = sort(flatten([for f, c in local.spoke_files : c if endswith(f, "prd")]))
  # mgmt 는 모든 VCN 을 모니터링 · 접근제어하므로 어느 그룹에도 넣지 않는다 (TRUST-INTRA default accept)
  nonprd_cidrs = sort(flatten([for f, c in local.spoke_files : c if !endswith(f, "prd") && f != "mgmt"]))

  vyos_vars = {
    for n, v in local.nvas : n => {
      eth = { for k, x in local.vnics : x.name => "eth${x.index}" if x.nva == n }
      mac = { for k, x in local.vnics : x.name => lower(x.primary ? data.oci_core_vnic.primary[n].mac_address : data.oci_core_vnic.secondary[k].mac_address) if x.nva == n }
      # primary(eth0)는 이미지 설정(DHCP, VRF MGMT)을 그대로 쓴다
      addr = {
        for k, x in local.vnics : x.name => x.primary ? [] : [
          for ip in concat([coalesce(x.private_ip, local.vnic_ips[k])], x.secondary_ips) : "${ip}/${split("/", local.hub_subnets[x.subnet].cidr)[1]}"
        ] if x.nva == n
      }
      gw     = { for k, x in local.vnics : x.name => cidrhost(local.hub_subnets[x.subnet].cidr, 1) if x.nva == n }
      spokes = local.spoke_cidrs
      prd    = local.prd_cidrs
      nonprd = local.nonprd_cidrs
    }
  }
}

locals {
  config_errors = concat(
    local.iam_ready ? [] : ["iam stack 이 아직 apply 되지 않았습니다: make apply-iam 을 먼저 실행하세요"],
    local.hub_ready ? [] : ["hub stack 이 아직 apply 되지 않았습니다: make apply-hub 를 먼저 실행하세요"],
    module.config.errors.nvas,
    flatten([
      for n, v in local.nvas_all : concat(
        [for f in ["compartment", "image", "shape", "ocpus", "memory_gb"] : "NVA ${n}: ${f} 가 없습니다" if try(v[f], null) == null],
        length(try(v.vnics, [])) > 0 ? [] : ["NVA ${n}: vnics 가 비었습니다 (첫 번째가 primary VNIC)"],
        !local.iam_ready || contains(keys(local.compartment_ids), try(v.compartment, "")) ? [] : ["NVA ${n}: compartment '${try(v.compartment, "")}' 가 없습니다 (compartments.yaml 과 00-iam apply 확인)"],
        alltrue([for x in try(v.vnics, []) : try(x.name, "") != ""]) && length(try(v.vnics, [])) == length(distinct([for x in try(v.vnics, []) : try(x.name, "")])) ? [] : ["NVA ${n}: vnics 의 name 이 비었거나 중복됩니다"],
        flatten([
          for i, x in try(v.vnics, []) : concat(
            !local.hub_ready || contains(keys(local.subnet_ids), try(x.subnet, "")) ? [] : ["NVA ${n}.vnics[${i}]: subnet '${try(x.subnet, "")}' 가 hub 에 없습니다"],
            contains(["ephemeral", "reserved", "none"], coalesce(try(x.public_ip, null), "none")) ? [] : ["NVA ${n}.vnics[${i}]: public_ip 는 ephemeral / reserved 중 하나입니다 (지금: ${x.public_ip})"],
            i > 0 || length(try(x.secondary_ips, [])) == 0 ? [] : ["NVA ${n}.vnics[0]: secondary_ips 는 secondary VNIC 에만 쓸 수 있습니다"],
            i < 4 ? [] : ["NVA ${n}.vnics[${i}]: VNIC 은 4개까지입니다 (primary 1 + secondary 3)"]
          )
        ])
      )
    ])
  )
}

resource "terraform_data" "config_check" {
  lifecycle {
    precondition {
      condition     = length(local.config_errors) == 0
      error_message = "config/ YAML 오류 ${length(local.config_errors)}건\n  - ${join("\n  - ", local.config_errors)}"
    }
  }
}

output "nva_ids" {
  value = { for k, i in oci_core_instance.this : k => i.id }
}

output "nva_vnics" {
  description = "VNIC 별 IP · MAC (VyOS 의 show interfaces 와 MAC 으로 대조한다)"
  value = {
    for k, x in local.vnics : k => {
      private_ip    = local.vnic_ips[k]
      secondary_ips = x.secondary_ips
      public_ip = (
        x.public_ip == "reserved" ? oci_core_public_ip.reserved[k].ip_address :
        x.primary ? oci_core_instance.this[x.nva].public_ip : data.oci_core_vnic.secondary[k].public_ip_address
      )
      mac = lower(x.primary ? data.oci_core_vnic.primary[x.nva].mac_address : data.oci_core_vnic.secondary[k].mac_address)
    }
  }
}

output "nva_ssh_host" {
  description = "NVA 관리 SSH 주소 (primary VNIC 의 public IP)"
  value = {
    for n, x in local.primary : n => (
      x.public_ip == "reserved" ? oci_core_public_ip.reserved["${n}|${x.name}"].ip_address : oci_core_instance.this[n].public_ip
    )
  }
}

output "vyos_config" {
  description = "VyOS 설정 스크립트 (make configure-nva 가 SSH 로 적용한다)"
  value       = { for n, v in local.vyos_vars : n => templatefile("${path.module}/vyos.sh.tftpl", v) }
}
