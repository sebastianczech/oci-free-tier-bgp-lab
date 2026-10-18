################################################################################
# Private Network Load Balancer in front of router-1 (Always Free: 1 NLB)
# A plain internal VIP: on-prem reaches nginx on 10.0.1.100:80 through the VPN.
# The NLB swaps the client source for its own IP (is_preserve_source = false),
# so router-1 replies to the NLB and the return path can't bypass it.
# Azure equivalent: internal Standard LB. AWS: internal Network Load Balancer.
################################################################################

resource "oci_network_load_balancer_network_load_balancer" "web" {
  compartment_id        = var.compartment_id
  display_name          = "${var.name_prefix}-nlb-web"
  subnet_id             = oci_core_subnet.nva.id
  assigned_private_ipv4 = local.ip.nlb
  is_private            = true
}

resource "oci_network_load_balancer_backend_set" "web" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.web.id
  name                     = "web"
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = false

  health_checker {
    protocol    = "HTTP"
    port        = 80
    url_path    = "/"
    return_code = 200
  }
}

resource "oci_network_load_balancer_backend" "router" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.web.id
  backend_set_name         = oci_network_load_balancer_backend_set.web.name
  name                     = "router-1"
  target_id                = oci_core_instance.router.id
  port                     = 80
}

resource "oci_network_load_balancer_listener" "web" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.web.id
  name                     = "http"
  default_backend_set_name = oci_network_load_balancer_backend_set.web.name
  protocol                 = "TCP"
  port                     = 80
}

################################################################################
# Public flexible Load Balancer, 10 Mbps (Always Free: 1 LB) -> nginx on router-1
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
  ip_address       = local.ip.router_1
  port             = 80
}

resource "oci_load_balancer_listener" "http" {
  load_balancer_id         = oci_load_balancer_load_balancer.app.id
  name                     = "http"
  default_backend_set_name = oci_load_balancer_backend_set.app.name
  port                     = 80
  protocol                 = "HTTP"
}

# Renamed when the lab moved from a router pair to router-1 only; keeps the existing NLB in state.
moved {
  from = oci_network_load_balancer_network_load_balancer.routers
  to   = oci_network_load_balancer_network_load_balancer.web
}

moved {
  from = oci_network_load_balancer_backend_set.routers
  to   = oci_network_load_balancer_backend_set.web
}

moved {
  from = oci_network_load_balancer_listener.routers
  to   = oci_network_load_balancer_listener.web
}
