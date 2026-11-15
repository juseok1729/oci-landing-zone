terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}

variable "tenancy_ocid" {
  type = string
}

variable "parent_ocid" {
  description = "상위 compartment OCID. null/빈 문자열이면 tenancy root"
  type        = string
  default     = null
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}

variable "compartments" {
  type = map(object({
    description = optional(string)
    ocid        = optional(string) # 있으면 생성하지 않고 참조만
  }))
  default  = {}
  nullable = false
}

resource "oci_identity_compartment" "this" {
  for_each = { for k, c in var.compartments : k => c if c.ocid == null }

  compartment_id = coalesce(var.parent_ocid, var.tenancy_ocid)
  name           = each.key
  description    = coalesce(each.value.description, each.key)

  # destroy 해도 실제 compartment 는 지우지 않고 state 에서만 제거 (안전장치)
  enable_delete = false
  freeform_tags = var.freeform_tags
}

# 새 compartment 는 다른 리전/서비스에 전파되기까지 시간이 걸려
# 바로 VCN 을 만들면 404 가 나는 경우가 있어 잠깐 대기
resource "time_sleep" "propagation" {
  create_duration = "60s"
  triggers = {
    ids = join(",", sort([for c in oci_identity_compartment.this : c.id]))
  }
}

output "ids" {
  description = "compartment 이름 → OCID"
  value = merge(
    { for k, c in var.compartments : k => c.ocid if c.ocid != null },
    { for k, c in oci_identity_compartment.this : k => c.id }
  )
  depends_on = [time_sleep.propagation]
}
