output "ssh" {
  description = "SSH commands."
  value = {
    cpe      = "ssh ubuntu@${oci_core_instance.cpe.public_ip}"
    router_1 = "ssh ubuntu@${oci_core_instance.router.public_ip}"
  }
}

output "app_url" {
  description = "nginx on router-1 through the public 10 Mbps load balancer."
  value       = "http://${oci_load_balancer_load_balancer.app.ip_address_details[0].ip_address}"
}

output "private_ips" {
  value = local.ip
}

output "vpn" {
  description = "OCI VPN headends and BGP sessions."
  value = {
    oracle_bgp_asn = local.oracle_bgp_asn
    tunnels = [for i, t in oci_core_ipsec_connection_tunnel_management.onprem : {
      headend     = t.vpn_ip
      oracle_bgp  = local.tunnels[i].oracle
      cpe_bgp     = local.tunnels[i].cpe
      status      = t.status
      bgp_session = t.bgp_session_info[0].bgp_state
    }]
  }
}
