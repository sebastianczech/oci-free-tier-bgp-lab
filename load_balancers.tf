################################################################################
# Private Network Load Balancer in front of the routers (Always Free: 1 NLB)
# Transparent next hop: source/destination preserved, symmetric hashing so both
# directions of a flow hit the same router. Azure equivalent: internal LB, HA ports.
################################################################################

resource "oci_network_load_balancer_network_load_balancer" "routers" {
  compartment_id                 = var.compartment_id
  display_name                   = "${var.name_prefix}-nlb-routers"
  subnet_id                      = oci_core_subnet.nva.id
  assigned_private_ipv4          = local.ip.nlb
  is_private                     = true
  is_preserve_source_destination = true
  is_symmetric_hash_enabled      = true
}

resource "oci_network_load_balancer_backend_set" "routers" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.routers.id
  name                     = "routers"
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol = "TCP"
    port     = 22
  }
}

resource "oci_network_load_balancer_backend" "router" {
  for_each = oci_core_instance.router

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.routers.id
  backend_set_name         = oci_network_load_balancer_backend_set.routers.name
  name                     = each.key
  target_id                = each.value.id
  port                     = 0
}

resource "oci_network_load_balancer_listener" "routers" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.routers.id
  name                     = "any"
  default_backend_set_name = oci_network_load_balancer_backend_set.routers.name
  protocol                 = "ANY"
  port                     = 0
}

################################################################################
# Public flexible Load Balancer, 10 Mbps (Always Free: 1 LB) -> nginx on the app VM
################################################################################

resource "oci_load_balancer_load_balancer" "app" {
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-lb-app"
  shape          = "flexible"
  subnet_ids     = [oci_core_subnet.lb.id]
  is_private     = false

  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 10
  }
}

resource "oci_load_balancer_backend_set" "app" {
  load_balancer_id = oci_load_balancer_load_balancer.app.id
  name             = "app"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol = "HTTP"
    port     = 80
    url_path = "/"
  }
}

resource "oci_load_balancer_backend" "app" {
  load_balancer_id = oci_load_balancer_load_balancer.app.id
  backendset_name  = oci_load_balancer_backend_set.app.name
  ip_address       = local.ip.app
  port             = 80
}

resource "oci_load_balancer_listener" "http" {
  load_balancer_id         = oci_load_balancer_load_balancer.app.id
  name                     = "http"
  default_backend_set_name = oci_load_balancer_backend_set.app.name
  port                     = 80
  protocol                 = "HTTP"
}
