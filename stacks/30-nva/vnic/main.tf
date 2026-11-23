# 같은 순번의 secondary VNIC (NVA 마다 1개). 30-nva 가 순번마다 한 번씩, 앞 순번이 다 붙은 뒤에 부른다.
terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

variable "vnics" {
  description = "\"<NVA>|<vnic name>\" → { instance_id, subnet_id, private_ip, public_ip, skip_source_dest_check }"
  type        = any
}

variable "tags" {
  type = map(string)
}

resource "oci_core_vnic_attachment" "this" {
  for_each = var.vnics

  instance_id  = each.value.instance_id
  display_name = replace(each.key, "|", "-")

  create_vnic_details {
    subnet_id              = each.value.subnet_id
    private_ip             = each.value.private_ip
    assign_public_ip       = each.value.public_ip == "ephemeral"
    skip_source_dest_check = each.value.skip_source_dest_check
    display_name           = replace(each.key, "|", "-")
    freeform_tags          = var.tags
  }
}

output "attachments" {
  value = oci_core_vnic_attachment.this
}
