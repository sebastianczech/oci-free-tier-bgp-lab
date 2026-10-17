################################################################################
# 4 VMs = the whole Always Free compute allowance
#   2 x VM.Standard.A1.Flex (1 OCPU, 6 GB)  -> router-1, router-2 (NVA pair)
#   2 x VM.Standard.E2.1.Micro              -> cpe (on-prem VPN + BGP), app (nginx)
# 4 boot volumes x 50 GB = the 200 GB Always Free block storage.
################################################################################

data "oci_core_images" "ubuntu_a1" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_core_images" "ubuntu_micro" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04 Minimal"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  boot_volume_gb = 50

  routers = {
    router-1 = { ip = local.ip.router_1, loopback = "10.255.0.1/32" }
    router-2 = { ip = local.ip.router_2, loopback = "10.255.0.2/32" }
  }
}

resource "oci_core_instance" "router" {
  for_each = local.routers

  compartment_id      = var.compartment_id
  availability_domain = local.ads[var.a1_ad_index]
  display_name        = "${var.name_prefix}-${each.key}"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 1
    memory_in_gbs = 6
  }

  create_vnic_details {
    subnet_id              = oci_core_subnet.nva.id
    private_ip             = each.value.ip
    assign_public_ip       = true
    skip_source_dest_check = true # forwards traffic that isn't addressed to it (Azure: IP forwarding on the NIC)
    hostname_label         = each.key
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_a1.images[0].id
    boot_volume_size_in_gbs = local.boot_volume_gb
  }

  metadata = {
    ssh_authorized_keys = local.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/templates/router-cloud-init.yaml.tftpl", {
      hostname   = each.key
      router_ip  = each.value.ip
      loopback   = each.value.loopback
      asn        = var.routers_asn
      cpe_ip     = local.ip.cpe
      cpe_asn    = var.onprem_asn
      app_subnet = local.app_subnet
      hub_cidr   = var.hub_cidr
      onprem     = [var.onprem_cidr, local.onprem_lan]
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

resource "oci_core_instance" "app" {
  compartment_id      = var.compartment_id
  availability_domain = local.ads[var.micro_ad_index]
  display_name        = "${var.name_prefix}-app"
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id        = oci_core_subnet.app.id
    private_ip       = local.ip.app
    assign_public_ip = false
    hostname_label   = "app"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_micro.images[0].id
    boot_volume_size_in_gbs = local.boot_volume_gb
  }

  metadata = {
    ssh_authorized_keys = local.ssh_public_key
    user_data           = base64encode(file("${path.module}/templates/app-cloud-init.yaml"))
  }

  preserve_boot_volume = false

  lifecycle {
    ignore_changes = [source_details[0].source_id]
  }

  # The app reaches the internet only through the NLB and routers, so they must exist first.
  depends_on = [oci_network_load_balancer_listener.routers, oci_network_load_balancer_backend.router]
}
