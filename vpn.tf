################################################################################
# DRG + Site-to-Site VPN (2 IPSec tunnels, BGP) between the hub and the CPE VM
################################################################################

resource "oci_core_drg" "hub" {
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-drg"
}

resource "oci_core_drg_attachment" "hub" {
  drg_id       = oci_core_drg.hub.id
  display_name = "${var.name_prefix}-drg-hub"

  network_details {
    id             = oci_core_vcn.hub.id
    type           = "VCN"
    route_table_id = oci_core_route_table.drg_ingress.id
  }
}

# The CPE VM sits behind the 1:1 NAT of its public IP, like a firewall behind a NAT device on-prem.
resource "oci_core_cpe" "onprem" {
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-cpe"
  ip_address     = oci_core_instance.cpe.public_ip
}

resource "oci_core_ipsec" "onprem" {
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-vpn"
  cpe_id         = oci_core_cpe.onprem.id
  drg_id         = oci_core_drg.hub.id
  static_routes  = [] # BGP only
}

data "oci_core_ipsec_connection_tunnels" "onprem" {
  ipsec_id = oci_core_ipsec.onprem.id
}

resource "random_password" "psk" {
  count   = 2
  length  = 32
  special = false
}

resource "oci_core_ipsec_connection_tunnel_management" "onprem" {
  count = 2

  ipsec_id      = oci_core_ipsec.onprem.id
  tunnel_id     = data.oci_core_ipsec_connection_tunnels.onprem.ip_sec_connection_tunnels[count.index].id
  display_name  = "${var.name_prefix}-tunnel-${count.index + 1}"
  routing       = "BGP"
  ike_version   = "V2"
  shared_secret = random_password.psk[count.index].result

  bgp_session_info {
    customer_bgp_asn      = var.onprem_asn
    customer_interface_ip = "${local.tunnels[count.index].cpe}/30"
    oracle_interface_ip   = "${local.tunnels[count.index].oracle}/30"
  }

  # Pinned on both sides (Libreswan config in templates/cpe-ipsec.conf.tftpl)
  phase_one_details {
    is_custom_phase_one_config      = true
    custom_encryption_algorithm     = "AES_256_CBC"
    custom_authentication_algorithm = "SHA2_384"
    custom_dh_group                 = "GROUP14"
    lifetime                        = 28800
  }

  phase_two_details {
    is_custom_phase_two_config  = true
    custom_encryption_algorithm = "AES_256_GCM"
    is_pfs_enabled              = true
    dh_group                    = "GROUP14"
    lifetime                    = 3600
  }
}

locals {
  oracle_bgp_asn = oci_core_ipsec_connection_tunnel_management.onprem[0].bgp_session_info[0].oracle_bgp_asn

  cpe_ipsec_conf = templatefile("${path.module}/templates/cpe-ipsec.conf.tftpl", {
    cpe_private_ip = local.ip.cpe
    cpe_public_ip  = oci_core_instance.cpe.public_ip
    tunnels = [for i, t in local.tunnels : merge(t, {
      vpn_ip = oci_core_ipsec_connection_tunnel_management.onprem[i].vpn_ip
    })]
  })

  cpe_ipsec_secrets = join("\n", [for i, t in oci_core_ipsec_connection_tunnel_management.onprem :
    "${oci_core_instance.cpe.public_ip} ${t.vpn_ip} : PSK \"${random_password.psk[i].result}\""
  ])

  cpe_frr_conf = templatefile("${path.module}/templates/cpe-frr.conf.tftpl", {
    cpe_ip      = local.ip.cpe
    asn         = var.onprem_asn
    oracle_asn  = local.oracle_bgp_asn
    tunnels     = local.tunnels
    routers     = [local.ip.router_1, local.ip.router_2]
    routers_asn = var.routers_asn
    loopbacks   = [for r in local.routers : r.loopback]
    hub_cidr    = var.hub_cidr
    networks    = [local.onprem_subnet, local.onprem_lan]
    lan_ip      = "${cidrhost(local.onprem_lan, 1)}/24"
  })
}

# The tunnel endpoints and keys only exist after the CPE VM (and its public IP) exist,
# so they cannot go into cloud-init. Terraform pushes them over SSH instead.
resource "terraform_data" "cpe_config" {
  triggers_replace = [
    oci_core_instance.cpe.id,
    sha256(local.cpe_ipsec_conf),
    sha256(local.cpe_ipsec_secrets),
    sha256(local.cpe_frr_conf),
  ]

  connection {
    type        = "ssh"
    host        = oci_core_instance.cpe.public_ip
    user        = "ubuntu"
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "file" {
    content     = local.cpe_ipsec_conf
    destination = "/tmp/oci-ipsec.conf"
  }

  provisioner "file" {
    content     = local.cpe_ipsec_secrets
    destination = "/tmp/oci-ipsec.secrets"
  }

  provisioner "file" {
    content     = local.cpe_frr_conf
    destination = "/tmp/frr.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait > /dev/null || true",
      "sudo install -m 600 -o root -g root /tmp/oci-ipsec.secrets /etc/ipsec.d/oci-ipsec.secrets",
      "sudo install -m 644 -o root -g root /tmp/oci-ipsec.conf /etc/ipsec.d/oci-ipsec.conf",
      "sudo install -m 640 -o frr -g frr /tmp/frr.conf /etc/frr/frr.conf",
      "rm -f /tmp/oci-ipsec.secrets /tmp/oci-ipsec.conf /tmp/frr.conf",
      "sudo systemctl enable ipsec && sudo systemctl restart ipsec",
      "sudo systemctl restart frr",
    ]
  }
}
