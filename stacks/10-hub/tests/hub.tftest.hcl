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
      compartment_ids = {
        HUB_COMP  = "ocid1.compartment.oc1..hub"
        PRD_COMP  = "ocid1.compartment.oc1..prd"
        DEV_COMP  = "ocid1.compartment.oc1..dev"
        MGMT_COMP = "ocid1.compartment.oc1..mgmt"
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
    condition     = length(output.bucket_names) == 0
    error_message = "현재 bucket 은 모두 spoke compartment 소속이라 hub 는 0개여야 합니다."
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
