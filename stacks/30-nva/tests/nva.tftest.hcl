# OCI 자격증명 없이 도는 테스트:  terraform init -backend=false && terraform test   (또는 make test)

mock_provider "time" {}

mock_provider "oci" {
  mock_data "oci_identity_availability_domains" {
    defaults = { availability_domains = [{ name = "MOCK:AP-SEOUL-1-AD-1" }] }
  }
  mock_data "oci_core_private_ips" {
    defaults = { private_ips = [{ id = "ocid1.privateip.oc1..mock", vnic_id = "ocid1.vnic.oc1..mock" }] }
  }
}

# 00-iam, 10-hub state 대신: config 의 compartment, hub subnet 이름 그대로 (+ tests/fixtures 전용 TEST_COMP)
override_data {
  target = data.terraform_remote_state.iam
  values = {
    outputs = {
      compartment_ids = merge(
        { TEST_COMP = "ocid1.compartment.oc1..test" },
        { for k, _ in yamldecode(file("../../config/compartments.yaml")).compartments : k => "ocid1.compartment.oc1..${lower(k)}" }
      )
    }
  }
}

override_data {
  target = data.terraform_remote_state.hub
  values = {
    outputs = {
      subnet_ids = { for k, _ in values(yamldecode(file("../../config/vcns/hub.yaml")))[0].subnets : k => "ocid1.subnet.oc1..${lower(k)}" }
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
    condition     = length(output.nva_ids) == length(yamldecode(file("../../config/nvas.yaml")).nvas)
    error_message = "nvas.yaml 의 NVA 가 모두 만들어져야 합니다."
  }
  assert {
    condition     = length(output.nva_vnics) == 4 && length(oci_core_private_ip.secondary) == 1 && length(oci_core_public_ip.reserved) == 1
    error_message = "NVA 는 VNIC 4(primary 1 + secondary 3), secondary IP 1(10.0.16.160), reserved public IP 1 이어야 합니다."
  }
  # YAML 순서 = 붙이는 순서 (vnic_1 → vnic_2 → vnic_3)
  assert {
    condition     = keys(module.vnic_1.attachments) == ["NVA|untrust"] && keys(module.vnic_2.attachments) == ["NVA|trust"] && keys(module.vnic_3.attachments) == ["NVA|ha"]
    error_message = "secondary VNIC 은 untrust → trust → ha 순서로 붙어야 합니다."
  }
  assert {
    condition     = module.vnic_1.attachments["NVA|untrust"].create_vnic_details[0].skip_source_dest_check && module.vnic_2.attachments["NVA|trust"].create_vnic_details[0].skip_source_dest_check && !module.vnic_3.attachments["NVA|ha"].create_vnic_details[0].skip_source_dest_check
    error_message = "skip source/dest check 는 untrust, trust 만 켜져 있어야 합니다."
  }
  assert {
    condition     = oci_core_instance.this["NVA"].create_vnic_details[0].assign_public_ip == "true" && !module.vnic_1.attachments["NVA|untrust"].create_vnic_details[0].assign_public_ip
    error_message = "mgmt(primary) 는 ephemeral public IP, untrust 는 reserved 라 ephemeral 이 없어야 합니다."
  }
  # VyOS 설정: 주소는 subnet prefix 와 함께, 경로, 그룹은 config/vcns 에서
  assert {
    condition = alltrue([for l in [
      "set interfaces ethernet eth1 address '10.0.0.11/24'",
      "set interfaces ethernet eth2 address '10.0.16.160/24'",
      "set interfaces ethernet eth3 address '10.0.48.4/28'",
      "set protocols static route 0.0.0.0/0 next-hop 10.0.0.1",
      "set protocols static route 10.5.0.0/16 next-hop 10.0.16.1",
      "set firewall group network-group VCN-PRD network '10.4.0.0/16'",
      "set firewall group network-group VCN-NONPRD network '10.5.0.0/16'",
      "delete firewall group network-group VCN-NONPRD",
      "set firewall zone MGMT member interface 'eth0'",
      "set service monitoring prometheus node-exporter listen-address '10.0.16.11'",
      "set firewall group network-group VCN-MGMT network '10.3.0.0/16'",
    ] : strcontains(output.vyos_config["NVA"], l)])
    error_message = "vyos_config 에 인터페이스 주소, 경로, 그룹이 config 대로 들어가야 합니다."
  }
  assert {
    condition     = !strcontains(output.vyos_config["NVA"], "VCN-NONPRD network '10.3.0.0/16'") && !strcontains(output.vyos_config["NVA"], "VCN-PRD network '10.3.0.0/16'")
    error_message = "mgmt(10.3) 는 VCN-PRD, VCN-NONPRD 어디에도 없어야 합니다 (모든 VCN 과 통신)."
  }
  assert {
    condition     = !strcontains(output.vyos_config["NVA"], "ethernet eth0 address")
    error_message = "primary(eth0)는 이미지 설정(DHCP)을 쓰므로 주소를 넣지 않습니다."
  }
}

# hub 를 apply 하기 전(빈 state): 안내 메시지로 멈춰야 한다
run "hub_not_applied" {
  command = plan

  override_data {
    target = data.terraform_remote_state.hub
    values = { outputs = {} }
  }

  expect_failures = [
    terraform_data.config_check,
  ]
}

run "broken_config_rejected" {
  command = plan

  variables {
    config_dir = "../../tests/fixtures/broken-nva"
  }

  expect_failures = [
    terraform_data.config_check,
  ]
}
