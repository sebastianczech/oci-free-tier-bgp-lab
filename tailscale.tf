################################################################################
# Optional: the CPE as a Tailscale subnet router (docs/articles/08-tailscale-subnet-router.md).
# Your laptop joins the simulated on-prem network over WireGuard and reaches the hub through
# the Site-to-Site VPN. Off unless tailscale_auth_key is set. No OCI resources: Tailscale runs
# on the existing CPE VM.
################################################################################

locals {
  tailscale_enabled = nonsensitive(var.tailscale_auth_key != null)
  tailscale_routes  = [var.hub_cidr, local.onprem_subnet, local.onprem_lan]
  tailnet_cidr      = "100.64.0.0/10" # Tailscale addresses (CGNAT range)

  tailscale_setup = [
    # Tailscale's own SNAT (MASQUERADE) would use the outgoing interface's address, which on vti1/vti2
    # is 169.254.x.x and unreachable from the hub. So it is off (--snat-subnet-routes=false) and this
    # rule rewrites tailnet sources to the CPE's own IP instead.
    "sudo iptables -t nat -C POSTROUTING -s ${local.tailnet_cidr} -o vti+ -j SNAT --to-source ${local.ip.cpe} 2>/dev/null || sudo iptables -t nat -A POSTROUTING -s ${local.tailnet_cidr} -o vti+ -j SNAT --to-source ${local.ip.cpe}",
    "sudo netfilter-persistent save",
    "command -v tailscale > /dev/null || curl -fsSL https://tailscale.com/install.sh | sudo sh",
    join(" ", [
      "sudo tailscale up --reset --auth-key=file:/tmp/tailscale.key",
      "--hostname=${var.name_prefix}-cpe",
      "--advertise-routes=${join(",", local.tailscale_routes)}",
      "--snat-subnet-routes=false;",
      "rc=$?; rm -f /tmp/tailscale.key; exit $rc",
    ]),
  ]
}

resource "terraform_data" "cpe_tailscale" {
  count      = local.tailscale_enabled ? 1 : 0
  depends_on = [terraform_data.cpe_config]

  triggers_replace = [
    oci_core_instance.cpe.id,
    sha256(jsonencode(local.tailscale_setup)),
  ]

  connection {
    type        = "ssh"
    host        = oci_core_instance.cpe.public_ip
    user        = "ubuntu"
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "file" {
    content     = var.tailscale_auth_key
    destination = "/tmp/tailscale.key"
  }

  provisioner "remote-exec" {
    inline = local.tailscale_setup
  }
}
