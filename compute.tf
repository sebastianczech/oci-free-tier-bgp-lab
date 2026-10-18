################################################################################
# 2 VMs = the Always Free E2.1.Micro allowance (no Ampere A1, so no "Out of host capacity")
#   cpe      -> on-prem VPN + BGP (Libreswan, FRR)
#   router-1 -> hub router: FRR (BGP to the CPE) + nginx behind both load balancers
# 2 boot volumes x 50 GB, within the 200 GB Always Free block storage.
################################################################################

data "oci_core_images" "ubuntu_micro" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04 Minimal"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  boot_volume_gb  = 50
  router_loopback = "10.255.0.1/32"
}

resource "oci_core_instance" "router" {
  compartment_id      = var.compartment_id
  availability_domain = local.ads[var.micro_ad_index]
  display_name        = "${var.name_prefix}-router-1"
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id        = oci_core_subnet.nva.id
    private_ip       = local.ip.router_1
    assign_public_ip = true
    hostname_label   = "router-1"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_micro.images[0].id
    boot_volume_size_in_gbs = local.boot_volume_gb
  }

  metadata = {
    ssh_authorized_keys = local.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/templates/router-cloud-init.yaml.tftpl", {
      hostname  = "router-1"
      router_ip = local.ip.router_1
      loopback  = local.router_loopback
      asn       = var.routers_asn
      cpe_ip    = local.ip.cpe
      cpe_asn   = var.onprem_asn
      onprem    = [var.onprem_cidr, local.onprem_lan]
    }))
  }

  preserve_boot_volume = false

  lifecycle {
    ignore_changes = [source_details[0].source_id] # don't rebuild when a newer image is published
  }
}

resource "oci_core_instance" "cpe" {
  compartment_id      = var.compartment_id
  availability_domain = local.ads[var.micro_ad_index]
  display_name        = "${var.name_prefix}-cpe"
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id              = oci_core_subnet.onprem.id
    private_ip             = local.ip.cpe
    assign_public_ip       = true
    skip_source_dest_check = true
    hostname_label         = "cpe"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_micro.images[0].id
    boot_volume_size_in_gbs = local.boot_volume_gb
  }

  metadata = {
    ssh_authorized_keys = local.ssh_public_key
    user_data           = base64encode(file("${path.module}/templates/cpe-cloud-init.yaml"))
  }

  preserve_boot_volume = false

  lifecycle {
    ignore_changes = [source_details[0].source_id]
  }
}
