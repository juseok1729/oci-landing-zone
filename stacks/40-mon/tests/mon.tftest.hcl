# OCI 자격증명 없이 도는 테스트:  terraform init -backend=false && terraform test   (또는 make test)

mock_provider "oci" {
  mock_data "oci_identity_availability_domains" {
    defaults = { availability_domains = [{ name = "MOCK:AP-SEOUL-1-AD-1" }] }
  }
  mock_data "oci_core_images" {
    defaults = { images = [{ id = "ocid1.image.oc1..ol9" }] }
  }
  mock_resource "oci_bastion_bastion" {
    defaults = { private_endpoint_ip_address = "10.3.16.200" }
  }
}

# 00-iam, 20-spoke(mgmt), 30-nva state 대신
override_data {
  target = data.terraform_remote_state.iam
  values = {
    outputs = {
      compartment_ids = { for k, _ in yamldecode(file("../../config/compartments.yaml")).compartments : k => "ocid1.compartment.oc1..${lower(k)}" }
    }
  }
}

override_data {
  target = data.terraform_remote_state.spoke
  values = {
    outputs = {
      vcn_ids    = { MGMT_VCN = "ocid1.vcn.oc1..mgmt" }
      subnet_ids = { for k, _ in values(yamldecode(file("../../config/vcns/mgmt.yaml")))[0].subnets : k => "ocid1.subnet.oc1..${lower(k)}" }
    }
  }
}

override_data {
  target = data.terraform_remote_state.nva
  values = {
    outputs = {
      nva_vnics = {
        "NVA|mgmt"    = { private_ip = "10.0.32.5" }
        "NVA|untrust" = { private_ip = "10.0.0.11" }
        "NVA|trust"   = { private_ip = "10.0.16.11" }
        "NVA|ha"      = { private_ip = "10.0.48.4" }
      }
    }
  }
}

variables {
  tenancy_ocid    = "ocid1.tenancy.oc1..mock"
  state_bucket    = "mock"
  state_namespace = "mock"
}

run "design_config_applies" {
  command = apply

  assert {
    condition     = local.spoke_ws == "mgmt" && oci_core_instance.this[0].create_vnic_details[0].subnet_id == "ocid1.subnet.oc1..mgmt_mon_pri_sbn" && oci_core_instance.this[0].create_vnic_details[0].private_ip == "10.3.16.10"
    error_message = "MON 은 mgmt state 의 MGMT_MON_PRI_SBN 에 10.3.16.10 으로 만들어져야 합니다."
  }
  assert {
    condition     = !oci_core_instance.this[0].create_vnic_details[0].assign_public_ip && oci_bastion_bastion.this[0].target_subnet_id == "ocid1.subnet.oc1..mgmt_mon_pri_sbn"
    error_message = "MON 은 공인 IP 없이, Bastion 은 같은 subnet 에 있어야 합니다."
  }
  # scrape 대상은 NVA 의 trust IP 만
  assert {
    condition     = jsonencode(output.prometheus_targets) == jsonencode(["10.0.16.11:9100"]) && strcontains(base64decode(oci_core_instance.this[0].metadata.user_data), "targets: [\"10.0.16.11:9100\"]")
    error_message = "Prometheus 는 NVA trust IP:9100 만 scrape 해야 합니다."
  }
  assert {
    condition = (
      keys(oci_core_network_security_group_security_rule.this) == ["192.168.10.0/24-3000", "bastion-22", "bastion-3000"] &&
      oci_core_network_security_group_security_rule.this["bastion-3000"].source == "10.3.16.200/32"
    )
    error_message = "NSG 는 Bastion IP → 22, 3000, grafana_from → 3000 만 열어야 합니다."
  }
}

# nva 를 apply 하기 전(빈 state): 안내 메시지로 멈춰야 한다
run "nva_not_applied" {
  command = plan

  override_data {
    target = data.terraform_remote_state.nva
    values = { outputs = {} }
  }

  expect_failures = [
    terraform_data.config_check,
  ]
}

run "broken_config_rejected" {
  command = plan

  variables {
    config_dir = "../../tests/fixtures/broken-mon"
  }

  expect_failures = [
    terraform_data.config_check,
  ]
}
