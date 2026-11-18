# OCI 자격증명 없이 도는 테스트:  terraform init -backend=false && terraform test   (또는 make test)
#   1. 실제 config/vcns/hub.yaml 이 검증을 통과하고 apply 그래프가 끝까지 도는지
#   2. privateip: target(FortiGate VIP), NSG/SL source_port 경로
#   3. 게이트웨이 RT 제약 위반을 plan 단계에서 막는지

mock_provider "oci" {
  mock_data "oci_core_services" {
    defaults = {
      services = [
        { id = "ocid1.service.oc1.ap-seoul-1.mockall", name = "All ICN Services In Oracle Services Network", cidr_block = "all-icn-services-in-oracle-services-network", description = "mock" },
        { id = "ocid1.service.oc1.ap-seoul-1.mockos", name = "OCI ICN Object Storage", cidr_block = "oci-icn-objectstorage", description = "mock" }
      ]
    }
  }
  mock_data "oci_objectstorage_namespace" {
    defaults = { namespace = "mocknamespace" }
  }
  mock_data "oci_core_private_ips" {
    defaults = { private_ips = [{ id = "ocid1.privateip.oc1.ap-seoul-1.mockfw", ip_address = "10.0.10.160" }] }
  }
}

# 00-iam state 대신
override_data {
  target = data.terraform_remote_state.iam
  values = {
    outputs = {
      # config/compartments.yaml 의 이름 그대로 (+ tests/fixtures 전용 TEST_COMP). compartment 를 바꿔도 테스트는 안 고친다
      compartment_ids = merge(
        { TEST_COMP = "ocid1.compartment.oc1..test" },
        { for k, _ in yamldecode(file("../../config/compartments.yaml")).compartments : k => "ocid1.compartment.oc1..${lower(k)}" }
      )
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
    condition     = length(output.subnet_ids) == 6
    error_message = "HUB subnet 은 6개여야 합니다."
  }
  assert {
    condition     = length(output.route_table_ids) == 7
    error_message = "HUB route table 은 7개(subnet 용 5 + SGW 1 + DRG attachment 1)여야 합니다."
  }
  assert {
    condition     = length(output.drg_attachment_ids) == 1 && length(output.drg_ids) == 1
    error_message = "hub stack 은 DRG 1개, attachment 1개를 만들어야 합니다."
  }
  assert {
    condition     = length(output.drg_route_table_ids) == 2
    error_message = "사용자 정의 DRG route table 은 2개(DRG_SPOKE_RT, DRG_IPSEC_RT)여야 합니다."
  }
  assert {
    condition     = sort(keys(output.bucket_names)) == sort(keys(yamldecode(file("../../config/buckets.yaml")).buckets))
    error_message = "bucket 은 모두 hub 가 만든다: buckets.yaml 의 bucket 이 전부 있어야 합니다 (지금 ${length(output.bucket_names)}개)."
  }
  assert {
    condition     = length(output.security_list_ids) == 4 && length(output.nsg_ids) == 2
    error_message = "HUB 는 SL 4개(DNS/FW_MGMT/UNTRUST/TRUST), NSG 2개(WAF_LB/WAF, NSG→NSG 규칙 포함)여야 합니다."
  }
}

run "privateip_nsg_source_port" {
  command = apply

  variables {
    config_dir = "../../tests/fixtures/privateip"
  }

  assert {
    condition     = length(output.route_table_ids) == 2 && length(output.nsg_ids) == 2 && length(output.security_list_ids) == 1
    error_message = "privateip fixture 의 RT 2, NSG 2(NSG→NSG 규칙 포함), SL 1 이 만들어져야 합니다."
  }
}

run "gateway_rt_constraints_rejected" {
  command = plan

  variables {
    config_dir = "../../tests/fixtures/broken-hub"
  }

  expect_failures = [
    terraform_data.config_check,
  ]
}

run "spokes_alias_expands" {
  command = apply

  variables {
    config_dir = "../../tests/fixtures/spokes"
  }

  assert {
    condition     = join(",", output.rule_destinations.vcn["HUB_SGW_RT"]) == "10.1.0.0/16,10.2.0.0/16,10.3.0.0/16"
    error_message = "HUB_SGW_RT 의 spokes 는 spoke CIDR 3개로 펼쳐져야 합니다: ${join(",", output.rule_destinations.vcn["HUB_SGW_RT"])}"
  }
  assert {
    condition     = join(",", output.rule_destinations.drg["DRG_IPSEC_RT"]) == "10.0.0.0/16,10.1.0.0/16,10.2.0.0/16,10.3.0.0/16"
    error_message = "DRG_IPSEC_RT 는 10.0.0.0/16 + spokes 3개여야 합니다: ${join(",", output.rule_destinations.drg["DRG_IPSEC_RT"])}"
  }
}

# iam 을 apply 하기 전(빈 state): Unsupported attribute 대신 config_check 의 안내 메시지로 멈춰야 한다
run "iam_not_applied" {
  command = plan

  override_data {
    target = data.terraform_remote_state.iam
    values = { outputs = {} }
  }

  expect_failures = [
    terraform_data.config_check,
  ]
}
