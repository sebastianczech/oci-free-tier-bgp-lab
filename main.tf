data "http" "my_ip" {
  count = var.my_ip_cidr == null ? 1 : 0
  url   = "https://api.ipify.org"
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.compartment_id
}

locals {
  my_ip_cidr = coalesce(var.my_ip_cidr, "${try(trimspace(data.http.my_ip[0].response_body), "")}/32")
  ads        = data.oci_identity_availability_domains.this.availability_domains[*].name

  # Fixed private IPs, so the BGP and route configs can be written up front.
  ip = {
    cpe      = cidrhost(local.onprem_subnet, 10) # 172.16.0.10
    router_1 = cidrhost(local.nva_subnet, 11)    # 10.0.1.11
    router_2 = cidrhost(local.nva_subnet, 12)    # 10.0.1.12
    nlb      = cidrhost(local.nva_subnet, 100)   # 10.0.1.100
    app      = cidrhost(local.app_subnet, 10)    # 10.0.2.10
  }

  lb_subnet     = cidrsubnet(var.hub_cidr, 8, 0)    # 10.0.0.0/24
  nva_subnet    = cidrsubnet(var.hub_cidr, 8, 1)    # 10.0.1.0/24
  app_subnet    = cidrsubnet(var.hub_cidr, 8, 2)    # 10.0.2.0/24
  onprem_subnet = cidrsubnet(var.onprem_cidr, 8, 0) # 172.16.0.0/24
  onprem_lan    = "192.168.100.0/24"                # loopback "LAN" on the CPE, advertised by BGP

  # BGP inside-tunnel addresses (link-local /30 per tunnel)
  tunnels = [
    { oracle = "169.254.10.1", cpe = "169.254.10.2", mark = 5 },
    { oracle = "169.254.20.1", cpe = "169.254.20.2", mark = 6 },
  ]

  ssh_public_key = file(pathexpand(var.ssh_public_key_path))
}
