# Your current public IP, allowed to SSH to the VMs. /ip returns plain text whatever the user agent.
data "http" "my_ip" {
  url = "https://ifconfig.me/ip"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && can(cidrhost("${trimspace(self.response_body)}/32", 0))
      error_message = "Could not detect your public IP from ifconfig.me."
    }
  }
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.compartment_id
}

locals {
  my_ip_cidr = "${trimspace(data.http.my_ip.response_body)}/32"
  ads        = data.oci_identity_availability_domains.this.availability_domains[*].name

  # Fixed private IPs, so the BGP and route configs can be written up front.
  ip = {
    cpe      = cidrhost(local.onprem_subnet, 10) # 172.16.0.10
    router_1 = cidrhost(local.nva_subnet, 11)    # 10.0.1.11
    nlb      = cidrhost(local.nva_subnet, 100)   # 10.0.1.100
  }

  lb_subnet     = cidrsubnet(var.hub_cidr, 8, 0)    # 10.0.0.0/24
  nva_subnet    = cidrsubnet(var.hub_cidr, 8, 1)    # 10.0.1.0/24
  onprem_subnet = cidrsubnet(var.onprem_cidr, 8, 0) # 172.16.0.0/24
  onprem_lan    = "192.168.100.0/24"                # loopback "LAN" on the CPE, advertised by BGP

  # BGP inside-tunnel addresses (link-local /30 per tunnel). OCI rejects 169.254.10-19.x, 169.254.100-109.x and 169.254.192-201.x.
  tunnels = [
    { oracle = "169.254.21.1", cpe = "169.254.21.2", mark = 5 },
    { oracle = "169.254.22.1", cpe = "169.254.22.2", mark = 6 },
  ]

  ssh_public_key = file(pathexpand(var.ssh_public_key_path))
}
