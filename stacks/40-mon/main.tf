#
# 40-mon : 모니터링 VM (Prometheus + Grafana, config/mon.yaml) + NSG + OCI Bastion
#   spoke(mgmt) subnet 에 붙고 NVA 를 scrape 하므로 mgmt, nva 다음에 apply 하고, 그보다 먼저 destroy 한다.
#
terraform {
  required_version = "~> 1.12"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
  }

  # bucket / namespace / region 은 backend.hcl 로 주입 (key 는 여기 고정. N.B. backend.hcl 에 key 를 넣지 않는다)
  backend "oci" {
    key = "lz/mon.tfstate"
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

module "config" {
  source     = "../../modules/config"
  config_dir = var.config_dir
}

locals {
  mon_all = module.config.mon
  # mon.yaml 의 subnet 이 있는 spoke 파일 = 읽을 spoke workspace
  spoke_ws = try(one([
    for f, d in module.config.vcn_files : f if f != "hub" && contains(keys(try(values(d)[0].subnets, {})), local.mon_all.subnet)
  ]), null)
}

data "terraform_remote_state" "iam" {
  backend = "oci"
  config  = merge(local.state_config, { key = "lz/iam.tfstate" })
}

data "terraform_remote_state" "spoke" {
  backend   = "oci"
  workspace = coalesce(local.spoke_ws, "default")
  config    = merge(local.state_config, { key = "lz/spoke.tfstate" })
}

data "terraform_remote_state" "nva" {
  backend = "oci"
  config  = merge(local.state_config, { key = "lz/nva.tfstate" })
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

locals {
  # 앞 stack 이 비어 있으면 Unsupported attribute 로 죽지 않고 config_check 의 안내 메시지로 멈춘다
  iam_ready       = can(data.terraform_remote_state.iam.outputs.compartment_ids)
  spoke_ready     = can(data.terraform_remote_state.spoke.outputs.subnet_ids)
  nva_ready       = can(data.terraform_remote_state.nva.outputs.nva_vnics)
  compartment_ids = try(data.terraform_remote_state.iam.outputs.compartment_ids, {})
  subnet_ids      = try(data.terraform_remote_state.spoke.outputs.subnet_ids, {})

  # 오류가 하나라도 있으면 아무것도 계획하지 않는다
  mon = length(local.config_errors) == 0 ? local.mon_all : null
  n   = local.mon == null ? 0 : 1

  # VyOS node-exporter (vyos.sh.tftpl): NVA 마다 trust VNIC IP:9100
  targets      = sort([for k, x in try(data.terraform_remote_state.nva.outputs.nva_vnics, {}) : "${x.private_ip}:9100" if endswith(k, "|trust")])
  ssh_key_file = try(pathexpand(local.mon_all.ssh_key_file), "")
  ssh_key      = local.ssh_key_file == "" ? null : (fileexists(local.ssh_key_file) ? file(local.ssh_key_file) : null)
  user_data    = templatefile("${path.module}/cloud-init.yaml.tftpl", { targets = local.targets })

  tags = { ManagedBy = "terraform", Stack = "mon" }
}

data "oci_core_images" "ol9" {
  count = local.n

  compartment_id           = var.tenancy_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = local.mon.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  # GPU, Developer 이미지 말고 일반 이미지 (e.g., Oracle-Linux-9.6-2025.10.23-0)
  filter {
    name   = "display_name"
    values = ["^Oracle-Linux-9\\.\\d+-\\d{4}"]
    regex  = true
  }
}

# Bastion 은 target subnet 안에 private endpoint 를 두고, 거기서 VM 의 22, 3000 으로 port forwarding 한다
resource "oci_bastion_bastion" "this" {
  count = local.n

  compartment_id               = local.compartment_ids[local.mon.compartment]
  bastion_type                 = "STANDARD"
  name                         = "MonBastion"
  target_subnet_id             = local.subnet_ids[local.mon.subnet]
  client_cidr_block_allow_list = local.mon.bastion_from
  freeform_tags                = local.tags
}

resource "oci_core_network_security_group" "this" {
  count = local.n

  compartment_id = local.compartment_ids[local.mon.compartment]
  vcn_id         = one(values(data.terraform_remote_state.spoke.outputs.vcn_ids))
  display_name   = "MON_NSG"
  freeform_tags  = local.tags
}

locals {
  # key 는 plan 때 알아야 하므로 Bastion IP 대신 이름으로 둔다
  nsg_rules = local.n == 0 ? {} : merge(
    { for p in ["22", "3000"] : "bastion-${p}" => { source = "${oci_bastion_bastion.this[0].private_endpoint_ip_address}/32", port = p } },
    { for c in try(local.mon.grafana_from, []) : "${c}-3000" => { source = c, port = "3000" } }
  )
}

resource "oci_core_network_security_group_security_rule" "this" {
  for_each = local.nsg_rules

  network_security_group_id = oci_core_network_security_group.this[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value.source
  source_type               = "CIDR_BLOCK"
  description               = each.key

  tcp_options {
    destination_port_range {
      min = tonumber(each.value.port)
      max = tonumber(each.value.port)
    }
  }
}

# cloud-init 은 첫 부팅에만 돌므로, 내용이 바뀌면 VM 을 다시 만든다
resource "terraform_data" "user_data" {
  input = local.user_data
}

resource "oci_core_instance" "this" {
  count = local.n

  compartment_id      = local.compartment_ids[local.mon.compartment]
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[try(local.mon.availability_domain, 1) - 1].name
  display_name        = "MON"
  shape               = local.mon.shape
  freeform_tags       = local.tags

  shape_config {
    ocpus         = local.mon.ocpus
    memory_in_gbs = local.mon.memory_gb
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ol9[0].images[0].id
  }

  create_vnic_details {
    subnet_id        = local.subnet_ids[local.mon.subnet]
    private_ip       = try(local.mon.private_ip, null)
    assign_public_ip = false
    nsg_ids          = [oci_core_network_security_group.this[0].id]
    display_name     = "MON-vnic"
    freeform_tags    = local.tags
  }

  metadata = merge(
    { user_data = base64encode(local.user_data) },
    local.ssh_key == null ? {} : { ssh_authorized_keys = local.ssh_key }
  )

  lifecycle {
    # 새 OL9 이미지가 나와도 VM 을 다시 만들지 않는다
    ignore_changes       = [source_details[0].source_id]
    replace_triggered_by = [terraform_data.user_data]
  }
}

locals {
  config_errors = concat(
    local.iam_ready ? [] : ["iam stack 이 아직 apply 되지 않았습니다: make apply-iam 을 먼저 실행하세요"],
    module.config.errors.mon,
    local.mon_all == null ? ["config/mon.yaml 에 mon 이 없습니다"] : concat(
      [for f in ["compartment", "subnet", "shape", "ocpus", "memory_gb", "ssh_key_file", "bastion_from"] : "mon: ${f} 가 없습니다" if try(local.mon_all[f], null) == null],
      local.spoke_ws != null ? [] : ["mon: subnet '${try(local.mon_all.subnet, "")}' 가 어느 spoke 에도 없습니다 (config/vcns)"],
      local.spoke_ws == null || local.spoke_ready ? [] : ["${local.spoke_ws} stack 이 아직 apply 되지 않았습니다: make apply-${local.spoke_ws} 를 먼저 실행하세요"],
      local.nva_ready ? [] : ["nva stack 이 아직 apply 되지 않았습니다: make apply-nva 를 먼저 실행하세요 (scrape 대상 IP)"],
      !local.iam_ready || contains(keys(local.compartment_ids), try(local.mon_all.compartment, "")) ? [] : ["mon: compartment '${try(local.mon_all.compartment, "")}' 가 없습니다 (compartments.yaml 과 00-iam apply 확인)"],
    )
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

output "prometheus_targets" {
  value = local.targets
}

output "grafana_url" {
  description = "Bastion 터널을 연 뒤 브라우저로 연다"
  value       = "http://localhost:3000"
}

output "grafana_tunnel" {
  description = "Grafana 를 여는 명령 (session 은 최대 3시간)"
  value = local.n == 0 ? null : join("\n", [
    "oci bastion session create-port-forwarding --bastion-id ${oci_bastion_bastion.this[0].id} --target-private-ip ${oci_core_instance.this[0].private_ip} --target-port 3000 --ssh-public-key-file ${local.mon.ssh_key_file} --wait-for-state SUCCEEDED --query 'data.resources[0].identifier' --raw-output",
    "ssh -i ${trimsuffix(local.mon.ssh_key_file, ".pub")} -N -L 3000:${oci_core_instance.this[0].private_ip}:3000 -p 22 <session OCID>@host.bastion.${var.region}.oci.oraclecloud.com",
  ])
}
