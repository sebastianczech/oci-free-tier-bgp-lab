################################################################################
# Hub VCN (the "cloud"): LB subnet, router subnet
################################################################################

resource "oci_core_vcn" "hub" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.hub_cidr]
  display_name   = "${var.name_prefix}-hub"
  dns_label      = "hub"
}

resource "oci_core_internet_gateway" "hub" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.hub.id
  display_name   = "${var.name_prefix}-hub-igw"
}

resource "oci_core_route_table" "lb" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.hub.id
  display_name   = "${var.name_prefix}-rt-lb"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.hub.id
  }
}

# Router and NLB: internet directly, on-prem through the DRG.
resource "oci_core_route_table" "nva" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.hub.id
  display_name   = "${var.name_prefix}-rt-nva"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.hub.id
  }
  route_rules {
    destination       = var.onprem_cidr
    network_entity_id = oci_core_drg.hub.id
  }
  route_rules {
    destination       = local.onprem_lan
    network_entity_id = oci_core_drg.hub.id
  }
}

# VCN ingress route table on the DRG attachment (Azure: UDR on GatewaySubnet). Empty: traffic
# from on-prem goes straight to its destination subnet. It is the hook for README exercise 5.
resource "oci_core_route_table" "drg_ingress" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.hub.id
  display_name   = "${var.name_prefix}-rt-drg-ingress"
}

resource "oci_core_security_list" "hub_internal" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.hub.id
  display_name   = "${var.name_prefix}-sl-hub-internal"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  ingress_security_rules {
    source   = var.hub_cidr
    protocol = "all"
  }
  ingress_security_rules {
    source   = var.onprem_cidr
    protocol = "all"
  }
  ingress_security_rules {
    source   = local.onprem_lan
    protocol = "all"
  }
  ingress_security_rules {
    source   = local.my_ip_cidr
    protocol = "6" # TCP
    tcp_options {
      min = 22
      max = 22
    }
  }
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1" # ICMP fragmentation needed (path MTU discovery)
    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_security_list" "lb_public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.hub.id
  display_name   = "${var.name_prefix}-sl-lb-public"

  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6"
    tcp_options {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_subnet" "lb" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.hub.id
  cidr_block        = local.lb_subnet
  display_name      = "${var.name_prefix}-lb"
  dns_label         = "lb"
  route_table_id    = oci_core_route_table.lb.id
  security_list_ids = [oci_core_security_list.hub_internal.id, oci_core_security_list.lb_public.id]
}

resource "oci_core_subnet" "nva" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.hub.id
  cidr_block        = local.nva_subnet
  display_name      = "${var.name_prefix}-nva"
  dns_label         = "nva"
  route_table_id    = oci_core_route_table.nva.id
  security_list_ids = [oci_core_security_list.hub_internal.id]
}

################################################################################
# On-prem VCN (simulated data centre): one public subnet with the CPE VM
################################################################################

resource "oci_core_vcn" "onprem" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.onprem_cidr]
  display_name   = "${var.name_prefix}-onprem"
  dns_label      = "onprem"
}

resource "oci_core_internet_gateway" "onprem" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.onprem.id
  display_name   = "${var.name_prefix}-onprem-igw"
}

resource "oci_core_route_table" "onprem" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.onprem.id
  display_name   = "${var.name_prefix}-rt-onprem"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.onprem.id
  }
}

resource "oci_core_security_list" "onprem" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.onprem.id
  display_name   = "${var.name_prefix}-sl-onprem"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  ingress_security_rules {
    source   = var.onprem_cidr
    protocol = "all"
  }
  ingress_security_rules {
    source   = local.my_ip_cidr
    protocol = "6"
    tcp_options {
      min = 22
      max = 22
    }
  }
  # IKE and NAT-T from the OCI VPN headends (their IPs are only known after the IPSec connection exists)
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "17" # UDP
    udp_options {
      min = 500
      max = 500
    }
  }
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "17"
    udp_options {
      min = 4500
      max = 4500
    }
  }
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1"
    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "onprem" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.onprem.id
  cidr_block        = local.onprem_subnet
  display_name      = "${var.name_prefix}-onprem"
  dns_label         = "dc"
  route_table_id    = oci_core_route_table.onprem.id
  security_list_ids = [oci_core_security_list.onprem.id]
}

################################################################################
# VCN flow logs on the router subnet
################################################################################

resource "oci_logging_log_group" "this" {
  count          = var.enable_flow_logs ? 1 : 0
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-logs"
}

resource "oci_logging_log" "nva_flow" {
  count        = var.enable_flow_logs ? 1 : 0
  display_name = "${var.name_prefix}-nva-flowlogs"
  log_group_id = oci_logging_log_group.this[0].id
  log_type     = "SERVICE"
  is_enabled   = true

  configuration {
    compartment_id = var.compartment_id
    source {
      category    = "all"
      resource    = oci_core_subnet.nva.id
      service     = "flowlogs"
      source_type = "OCISERVICE"
    }
  }

  retention_duration = 30
}
