# OCI Always Free BGP lab

A hub-and-spoke network lab on Oracle Cloud that stays inside the [Always Free](https://www.oracle.com/cloud/free/) limits. It uses BGP on VMs (FRR), a Site-to-Site VPN with BGP to a simulated on-prem data centre, a pair of router VMs behind a transparent Network Load Balancer, and a public Load Balancer. It practises the same patterns as an Azure transit VNet with NVAs: UDRs to an internal LB, GatewaySubnet routing, and BGP over VPN. The [Azure mapping](#azure-mapping) and [AWS mapping](#aws-mapping) sections list the equivalents.

Everything is vendor-neutral: Ubuntu 24.04, FRR, Libreswan and iptables. Nothing here needs a licence.

## Topology

![Topology: hub VCN with public LB, router pair behind a private NLB and the app VM; on-prem VCN with the CPE; DRG and two IPSec tunnels with BGP; inbound, outbound and on-prem flows](diagrams/topology.png)

*Editable source: [`topology.excalidraw.svg`](diagrams/topology.excalidraw.svg) (open in Excalidraw).*

**Route tables**

| Where | Destination | Next hop | Why |
|---|---|---|---|
| `lb` subnet | 0.0.0.0/0 | Internet gateway | public LB |
| `nva` subnet | 0.0.0.0/0 | Internet gateway | routers' own traffic and SNAT'd app egress |
| `nva` subnet | 172.16.0.0/16, 192.168.100.0/24 | DRG | routers → on-prem |
| `app` subnet | 0.0.0.0/0, 172.16.0.0/16, 192.168.100.0/24 | NLB private IP 10.0.1.100 | everything leaving the VCN goes through the routers |
| DRG attachment (VCN ingress) | 10.0.2.0/24 | NLB private IP 10.0.1.100 | on-prem → app goes through the routers |
| DRG (auto, BGP) | 172.16.0.0/24, 192.168.100.0/24 | IPSec tunnels | learned from the CPE |

## Packet flows

**On-prem → app** (`ping 10.0.2.10` from the CPE):
1. The CPE has learned 10.0.0.0/16 by BGP from both tunnels, so the packet leaves through `vti1` or `vti2`. The source is 172.16.0.10, because the `SET-SRC` route-map stops Linux from using the 169.254 tunnel address.
2. The OCI VPN headend decrypts the packet and the DRG forwards it to the hub VCN attachment.
3. The attachment's **ingress route table** sends 10.0.2.0/24 to the NLB, not straight to the subnet.
4. The NLB keeps the source and destination unchanged and hashes the flow to one router. Symmetric hashing gives the reply the same hash.
5. The router forwards the packet (`ip_forward`, skip source/destination check on its VNIC) to 10.0.2.10.
6. The reply: the app subnet route 172.16.0.0/16 → NLB sends it to **the same router**, then the `nva` route 172.16.0.0/16 → DRG, then the tunnel, then the CPE.

**App → internet** (`curl ifconfig.me` from the app VM):
1. The app subnet's 0.0.0.0/0 → NLB route sends the packet to a router.
2. The router SNATs the packet to its own private IP (iptables `MASQUERADE` for traffic leaving the hub and on-prem ranges).
3. The `nva` route 0.0.0.0/0 → internet gateway applies, and the IGW maps the router's private IP to the router's public IP. `curl ifconfig.me` therefore returns a **router's** public IP.
4. The reply comes back to that router (the IGW reverses its mapping, then conntrack undoes the SNAT), and the router forwards it to the app.

**Internet → app** (`curl <app_url>`):
1. The public LB (a full proxy) opens a new connection from its own private IP in `lb` to 10.0.2.10:80.
2. The reply goes to the LB inside the VCN, so it never touches the routers and return-path symmetry isn't an issue.

## BGP sessions

| Session | Type | Path | What is exchanged |
|---|---|---|---|
| CPE ↔ DRG, ×2 | eBGP 65010 ↔ 31898 over VTI | inside each IPSec tunnel | The CPE advertises 172.16.0.0/24 and 192.168.100.0/24 (prefix-list `ONPREM`). The DRG advertises 10.0.0.0/16. Every session has an `in` and an `out` route-map (see [Exercises](#exercises)). |
| CPE ↔ router-1, router-2 | eBGP multihop 65010 ↔ 65020 | across the VPN, TCP 179 | The routers advertise their loopbacks 10.255.0.x/32. The CPE advertises the on-prem prefixes. |

![BGP sessions: CPE to DRG over both tunnels, CPE to both routers multihop through the VPN; the routers' loopbacks are not reachable because the DRG never learns them](diagrams/bgp-sessions.png)

*Editable source: [`bgp-sessions.excalidraw.svg`](diagrams/bgp-sessions.excalidraw.svg) (open in Excalidraw).*

The second session holds the **key lesson**, which is the same one as in Azure. BGP between VMs only changes the VMs' own routing tables. The CPE learns 10.255.0.1/32, but a ping to it fails: the packet goes into the tunnel, and the DRG has no route for 10.255.0.0/24 because nothing advertised it to OCI. OCI has no equivalent of Azure Route Server or AWS VPC Route Server, so a VM can't program the VCN or DRG with BGP. Only the DRG's own sessions over IPSec or FastConnect do that.

## Always Free usage

| Resource | Used | Always Free limit |
|---|---|---|
| Ampere A1 | router-1, router-2: 1 OCPU + 6 GB each | 2 OCPU, 12 GB in total |
| E2.1.Micro | cpe, app | 2 |
| Boot volumes | 4 × 50 GB | 200 GB |
| VCNs | hub, onprem | 2 (Free Tier accounts) |
| Flexible Load Balancer | 1, 10 Mbps | 1 |
| Network Load Balancer | 1 | 1 |
| Site-to-Site VPN | 1 connection, 2 IPSec tunnels | 50 IPSec connections |
| DRG | 1 | Oracle lists no charge for DRG |
| Public IPs | 3 ephemeral (cpe, routers) | ephemeral IPs on Always Free VMs |
| Flow logs | `nva` subnet | 10 GB/month |
| NAT gateway | **not used**: the app goes out through the routers instead | n/a |

Sources: [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) · [Dynamic Routing Gateway](https://www.oracle.com/cloud/networking/dynamic-routing-gateway/) · [VCN pricing](https://www.oracle.com/cloud/networking/virtual-cloud-network/pricing/)

> ⚠️ **Check after the first apply.** On a Pay-As-You-Go account, anything over the limits above is billed. Look at *Billing → Cost Analysis* the next day, and set a budget alert (for example $1) beforehand. Oracle can reclaim Always Free VMs that stay idle for 7 days, so destroy the lab between sessions.

## Deploy

Prerequisites: an OCI account (home region = `region`), `~/.oci/config` with an API key, Terraform ≥ 1.5, and an SSH key pair. Terraform SSHes to the CPE VM to push the VPN config, so it uses `ssh_private_key_path`.

```bash
cp terraform.tfvars.example terraform.tfvars   # set region, config_file_profile, compartment_id
terraform init
terraform plan -out=lab.tfplan
terraform apply lab.tfplan                     # ~10-15 min, mostly the VPN and cloud-init
terraform output
```

If you get **"Out of host capacity"** for A1, change `a1_ad_index` or retry later. Micro VMs only work in one AD in multi-AD regions. If they fail, try `micro_ad_index` = 1 or 2.

## Test

```bash
# CPE: tunnels and BGP
ssh ubuntu@<cpe>
sudo ipsec trafficstatus                     # both tunnels with traffic counters
sudo vtysh -c "show bgp summary"             # 2 OCI peers + 2 routers Established
sudo vtysh -c "show ip route bgp"            # 10.0.0.0/16 via vti1 and vti2 (ECMP), 10.255.0.x/32
ping -c3 10.0.2.10                           # on-prem → app through DRG, NLB, router
ping -c3 -I 192.168.100.1 10.0.2.10          # from the on-prem "LAN"
ping -c3 10.255.0.1                          # fails: see "BGP sessions" above

# Router: see traffic flowing through
ssh ubuntu@<router-1>
sudo tcpdump -ni any icmp or port 80         # run on both routers, ping from the CPE
sudo vtysh -c "show bgp summary"

# App (private, via router-1)
ssh -J ubuntu@<router-1> ubuntu@10.0.2.10
curl -s ifconfig.me                          # = public IP of router-1 or router-2 (SNAT)
traceroute -n 172.16.0.10

# From your Mac
curl http://<lb-ip>                          # app_url output
```

In the OCI console, *Networking → Site-to-Site VPN → tunnels* shows the IPSec and BGP status. *DRG → DRG route tables → Get all route rules* shows the BGP-learned on-prem routes.

## Exercises

The exercises build on each other but each one ends with a cleanup step, so you can do them in any order. Each one has an **Azure link** and an **AWS link** that names the same decision in those clouds. The expected outputs come from the configs and FRR's documented behaviour; they have not been captured from a live run yet.

Run FRR commands with `sudo vtysh` (or `sudo vtysh -c "<command>"`). In the configs every eBGP neighbor has an `in` and an `out` route-map: with `frr defaults traditional`, FRR applies [RFC 8212](https://datatracker.ietf.org/doc/html/rfc8212) (`bgp ebgp-requires-policy`), so a session without policy is Established but exchanges nothing.

| VM | AS | Neighbors | Accepts (`in`) | Sends (`out`) |
|---|---|---|---|---|
| cpe | 65010 | DRG `169.254.10.1`, `169.254.20.1` (peer-group `OCI`) | `FROM-OCI`: 10.0.0.0/16 and longer | `ONPREM-ONLY`: 172.16.0.0/24, 192.168.100.0/24 |
| cpe | 65010 | router-1 `10.0.1.11`, router-2 `10.0.1.12` (peer-group `ROUTERS`) | `FROM-ROUTERS`: 10.255.0.1/32, 10.255.0.2/32 | `ONPREM-ONLY` |
| router-1, router-2 | 65020 | cpe `172.16.0.10` | `FROM-CPE`: 172.16.0.0/16, 192.168.100.0/24 and longer | `TO-CPE`: its own loopback |

### Exercise 1: Sessions and the state machine

On the CPE:

```
show bgp summary
show bgp neighbors 169.254.10.1
show ip route bgp
```

All four neighbors should show a number in `State/PfxRcd` (*Established*): 1 prefix (10.0.0.0/16) from each DRG peer, 1 loopback from each router. In `show bgp neighbors 169.254.10.1`, find the remote AS (31898, Oracle's ASN), the hold time, and `External BGP neighbor may be up to 1 hops away`. For `10.0.1.11` the same line says `up to 5 hops` (`ebgp-multihop 5`). `show ip route bgp` shows 10.0.0.0/16 with two next hops, one per VTI (`maximum-paths 2`).

Break and fix: take one tunnel down and watch its BGP session drop to `Active` while 10.0.0.0/16 stays reachable over the other one:

```bash
sudo ipsec auto --down oci-tunnel-1
sudo vtysh -c "show bgp summary"           # 169.254.10.1 Active/Connect, 169.254.20.1 still up
ping -c3 10.0.2.10                         # still works through vti2
sudo ipsec auto --up oci-tunnel-1
```

In the console, *Site-to-Site VPN → Tunnels* shows tunnel 1 *Down* and its BGP status *Down*.

**Azure link:** an active-active VPN Gateway also has two instances and two BGP peers; the on-prem device loses one session, not connectivity.
**AWS link:** every Site-to-Site VPN connection has two tunnels, each with its own BGP session; AWS performs maintenance on one at a time, so both must be up.

### Exercise 2: eBGP requires policy

On router-1, remove the inbound policy:

```
conf t
router bgp 65020
 address-family ipv4 unicast
  no neighbor 172.16.0.10 route-map FROM-CPE in
end
clear bgp 172.16.0.10 soft in
show bgp summary
show bgp neighbors 172.16.0.10
```

The session stays Established, but `PfxRcd` shows `(Policy)` and the neighbor output says `Inbound updates discarded due to missing policy`. `show ip route bgp` is now empty. Put it back with `neighbor 172.16.0.10 route-map FROM-CPE in` and the same soft clear.

Try the same on the CPE with `no neighbor OCI route-map FROM-OCI in`: the CPE loses 10.0.0.0/16, and `ping 10.0.2.10` leaves through the internet gateway instead of the tunnels and fails.

**Azure link:** filter what an NVA accepts from Azure Route Server and what it advertises to it. A missing export filter can push a default route to every VNet that ARS feeds.
**AWS link:** VPC Route Server and Transit Gateway Connect peers are ordinary eBGP sessions. Filter both directions on the appliance.

### Exercise 3: AS path and loop prevention

Both routers are in AS 65020, like two NVAs that share an ASN. Let the CPE pass each router's loopback on to the other router:

```
# cpe
conf t
route-map TO-ROUTERS permit 10
 match ip address prefix-list ONPREM
route-map TO-ROUTERS permit 20
 match ip address prefix-list LOOPBACKS
router bgp 65010
 address-family ipv4 unicast
  neighbor ROUTERS route-map TO-ROUTERS out
end
clear bgp 10.0.1.12 soft out

# router-2
conf t
ip prefix-list ONPREM permit 10.255.0.0/24 le 32
end
clear bgp 172.16.0.10 soft in
```

On the CPE, `show bgp neighbors 10.0.1.12 advertised-routes` lists 10.255.0.1/32 with path `65020`. On router-2 the prefix is still missing from `show bgp ipv4 unicast`: its path would be `65010 65020`, and router-2 is in 65020, so it treats the route as a loop and drops it.

Accept it anyway:

```
# router-2
conf t
router bgp 65020
 address-family ipv4 unicast
  neighbor 172.16.0.10 allowas-in 1
end
show bgp ipv4 unicast 10.255.0.1/32
```

The route now appears with path `65010 65020` and next hop 172.16.0.10. Run `ping -c3 10.255.0.1` from router-2: it still fails. The kernel resolves the next hop through the default route to the VCN gateway, and the VCN has no route for 10.255.0.1 (exercise 7).

**Azure link:** this is why an NVA can't hand Azure Route Server back a route that ARS learned from the VPN/ER gateway: the path already contains 65515, so ARS drops it.
**AWS link:** the same eBGP rule applies to the Amazon-side ASN of a virtual private gateway or Transit Gateway: a path that already contains it is dropped.

Clean up: on router-2 `no neighbor 172.16.0.10 allowas-in 1` and `no ip prefix-list ONPREM permit 10.255.0.0/24 le 32`; on the CPE `neighbor ROUTERS route-map ONPREM-ONLY out` and `no route-map TO-ROUTERS`; then soft clears.

### Exercise 4: Tunnel preference with AS-path prepending

Make tunnel 2 the backup for traffic coming *from* OCI:

```
# cpe
conf t
route-map OCI-T2-OUT permit 10
 match ip address prefix-list ONPREM
 set as-path prepend 65010 65010
router bgp 65010
 address-family ipv4 unicast
  neighbor 169.254.20.1 route-map OCI-T2-OUT out
end
clear bgp 169.254.20.1 soft out
```

In the console, *DRG → DRG route tables → Get all route rules* still lists 172.16.0.0/24 and 192.168.100.0/24, now only through tunnel 1. Ping the CPE from the app VM and watch `sudo ipsec trafficstatus` on the CPE: only tunnel 1's inbound counter grows. The CPE still sends its own traffic over both tunnels (ECMP). That asymmetry is fine for the DRG; to make tunnel 2 the backup in both directions, also lower `local-preference` for routes learned from 169.254.20.1 with an `in` route-map.

**Azure link:** prepending on one link of an active-active VPN or ExpressRoute is how on-prem picks the primary path into Azure.
**AWS link:** AWS also prefers the shorter AS path when choosing between VPN tunnels, so prepending sets the active tunnel.

Clean up: `neighbor 169.254.20.1 route-map ONPREM-ONLY out`, `no route-map OCI-T2-OUT`, then the soft clear.

### Exercise 5: Router failover

The NLB health check is TCP 22 from the NLB itself. Keep a ping running from the CPE to 10.0.2.10 and `sudo tcpdump -ni any icmp` on both routers, then make router-1 fail the check without breaking your own SSH session:

```bash
# router-1
sudo iptables -I INPUT -p tcp --dport 22 -s 10.0.1.0/24 -j DROP
```

After the health check marks router-1 *Critical* (*Network Load Balancer → Backend sets → routers → Backends*), the ICMP flow shows up on router-2. Remove the rule with `sudo iptables -D INPUT -p tcp --dport 22 -s 10.0.1.0/24 -j DROP`, and router-1 becomes *OK* again.

**Azure link:** the internal Standard LB with HA ports removes a firewall from rotation when its health probe fails.
**AWS link:** Gateway Load Balancer stops sending new flows to an appliance whose target health check fails.

### Exercise 6: Symmetric hashing

From the CPE, open many TCP flows and watch which router sees each direction:

```bash
# router-1 and router-2
sudo tcpdump -ni any 'tcp port 80 and tcp[tcpflags] & (tcp-syn) != 0'

# cpe
for i in $(seq 20); do curl -s -o /dev/null http://10.0.2.10/; done
```

With `is_symmetric_hash_enabled = true`, the SYN and the SYN-ACK of each flow appear on the same router. Set it to `false` in `load_balancers.tf`, run `terraform apply`, and repeat: some flows now have the SYN on one router and the SYN-ACK on the other. The flows still work, because these routers don't do stateful filtering. A stateful firewall would drop the SYN-ACK it never saw a SYN for. Set it back to `true` afterwards.

**Azure link:** the internal LB with HA ports hashes both directions of a flow to the same backend, which is why the firewall sandwich works.
**AWS link:** Gateway Load Balancer keeps flow stickiness on the 5-tuple in both directions for the same reason.

### Exercise 7: Make the loopbacks reachable

The CPE has 10.255.0.1/32 in its routing table, but `ping 10.255.0.1` fails (see [BGP sessions](#bgp-sessions)). Advertising 10.255.0.0/24 from the CPE to OCI doesn't help: the DRG would learn it from the tunnel and send it straight back.

Find a configuration that makes `ping -I 192.168.100.1 10.255.0.1` from the CPE work. Hints: which DRG route table decides where the DRG sends traffic for a prefix, can it point at the hub VCN attachment, and what can the attachment's ingress route table do with a destination that is not a subnet? Check the [VCN route table](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingroutetables.htm#Route) rules for private IP targets before you start. Make the change in Terraform (`vpn.tf`, `network.tf`), not in the console, so `terraform destroy` still cleans up.

**Azure link:** Azure Route Server learns 10.255.0.1/32 from the NVA over BGP and programs it into the VNet and the VPN gateway, so none of the static work is needed.
**AWS link:** VPC Route Server does the same for VPC route tables (next hop = the appliance's ENI); a Transit Gateway learns it through a Connect attachment.

### Exercise 8: Flow logs

*Logging → Log groups → bgp-lab-logs → nva flow log* shows accepted flows on the router VNICs. Ping 10.0.2.10 from the CPE, wait a few minutes, and find the records with source 172.16.0.10 and destination 10.0.2.10. They are logged on the router VNIC, even though neither address belongs to it, because the router forwards the packet. Do the same for `curl ifconfig.me` from the app VM and find the SNAT'd flow from the router to the internet.

**Azure link:** VNet flow logs (the successor to NSG flow logs) record the same transit traffic on the NVA's NIC.
**AWS link:** VPC Flow Logs on the appliance ENI; with GWLB, the flows show up on the GWLB endpoint and the appliance ENI.

### Exercise 9: Watch BGP on the wire

On router-1:

```bash
sudo tcpdump -ni any -v tcp port 179
```

In another session run `sudo vtysh -c "clear bgp 172.16.0.10"` and watch the OPEN, KEEPALIVE and UPDATE messages. With `-v`, tcpdump prints the IP TTL: the session crosses the VCN, the DRG, the tunnel and the on-prem VCN, which is why `ebgp-multihop` is needed. On the CPE, `sudo tcpdump -ni vti1 tcp port 179` shows the session with the DRG inside tunnel 1. Those packets are never visible on `ens3`, which only carries ESP over UDP 4500.

## Destroy

```bash
terraform destroy
```

## Azure mapping

| This lab (OCI) | Azure equivalent |
|---|---|
| DRG + Site-to-Site VPN, BGP | VPN Gateway (active-active) + Local Network Gateway, BGP |
| VCN ingress route table on the DRG attachment | UDR on GatewaySubnet |
| Private NLB, preserve source/destination, symmetric hash, ANY/0 | Internal Standard LB, HA ports |
| Route rule → NLB private IP | UDR next hop *Virtual appliance* = ILB frontend IP |
| `skip_source_dest_check` on the router VNIC | IP forwarding on the NIC |
| Security lists | NSGs |
| No equivalent | Azure Route Server (NVA ↔ fabric BGP) |

* [About active-active mode VPN gateways](https://learn.microsoft.com/en-us/azure/vpn-gateway/about-active-active-gateways): two gateway instances, two tunnels and two BGP peers, like the two OCI tunnels
* [About BGP and VPN Gateway](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-bgp-overview): BGP over S2S VPN, ASN 65515, APIPA peer addresses
* [Modify local network gateway settings using the Azure portal](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-modify-local-network-gateway-portal): the on-prem side (OCI CPE object)
* [About VPN Gateway configuration settings](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings#gwsub): GatewaySubnet rules (UDRs allowed, but no 0.0.0.0/0 and no NSG)
* [Azure virtual network traffic routing](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-udr-overview): UDRs and the *Virtual appliance* next hop
* [High availability ports overview](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-ha-ports-overview): the internal LB rule that matches the NLB's ANY/0 listener
* [Create, change, or delete a network interface](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-network-interface#enable-or-disable-ip-forwarding): IP forwarding on the NIC
* [Azure network security groups overview](https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview): stateful rules on subnets and NICs
* [What is Azure Route Server?](https://learn.microsoft.com/en-us/azure/route-server/overview): BGP between NVAs and the VNet, which OCI doesn't have

## AWS mapping

| This lab (OCI) | AWS equivalent |
|---|---|
| DRG + Site-to-Site VPN, BGP | Virtual private gateway or Transit Gateway + Customer gateway + Site-to-Site VPN (two tunnels), BGP |
| VCN ingress route table on the DRG attachment | Gateway route table with an edge association to the virtual private gateway (ingress routing) |
| Private NLB, preserve source/destination, symmetric hash, ANY/0 | Gateway Load Balancer (GENEVE, so the appliances must handle encapsulation) |
| Route rule → NLB private IP | Route target = Gateway Load Balancer endpoint |
| `skip_source_dest_check` on the router VNIC | Disable source/destination check on the ENI |
| Security lists (subnet scope, stateful) | Security groups (stateful); network ACLs are subnet scope but stateless |
| Public Load Balancer | Application Load Balancer |
| No equivalent | VPC Route Server (NVA ↔ VPC route table BGP), or Transit Gateway Connect (GRE + BGP to the TGW) |

* [How AWS Site-to-Site VPN works](https://docs.aws.amazon.com/vpn/latest/s2svpn/how_it_works.html): virtual private gateway, Transit Gateway and customer gateway
* [Tunnel options for your AWS Site-to-Site VPN connection](https://docs.aws.amazon.com/vpn/latest/s2svpn/VPNTunnels.html): two tunnels per connection, inside CIDRs (169.254.x.x/30), IKE settings
* [AWS Site-to-Site VPN customer gateway devices](https://docs.aws.amazon.com/vpn/latest/s2svpn/your-cgw.html): what the CPE has to do, including BGP
* [AWS Site-to-Site VPN attachments in AWS Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/tgw-vpn-attachments.html): VPN terminated on a TGW instead of a VGW
* [Gateway route tables](https://docs.aws.amazon.com/vpc/latest/userguide/gateway-route-tables.html): ingress routing on the virtual private gateway, the DRG attachment ingress route table equivalent
* [What is a Gateway Load Balancer?](https://docs.aws.amazon.com/elasticloadbalancing/latest/gateway/introduction.html): transparent load balancing for appliances, GENEVE, flow stickiness
* [Access an inspection system using a Gateway Load Balancer endpoint](https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-load-balancer-endpoints.html): the GWLB endpoint as a route target
* [Modify network interface attributes](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/modify-network-interface-attributes.html): the source/destination check setting on an ENI
* [Control traffic to your AWS resources using security groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html): stateful, per ENI
* [Control subnet traffic with network access control lists](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html): stateless, per subnet
* [What is an Application Load Balancer?](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html): the full-proxy HTTP LB, like the OCI public LB
* [Dynamic routing in your VPC using VPC Route Server](https://docs.aws.amazon.com/vpc/latest/userguide/dynamic-routing-route-server.html): BGP from appliances into VPC route tables, which OCI doesn't have
* [Connect attachments and Connect peers in AWS Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/tgw-connect.html): GRE + BGP between an appliance and a Transit Gateway

## Files

- `network.tf`: VCNs, subnets, route tables, security lists, flow logs
- `vpn.tf`: DRG, CPE, IPSec connection, tunnels (BGP, IKEv2), and the SSH push of the CPE config
- `compute.tf`: the 4 VMs
- `load_balancers.tf`: the NLB in front of the routers and the public LB in front of the app
- `templates/`: cloud-init for each VM, plus the Libreswan and FRR config templates for the CPE
- `diagrams/`: Excalidraw diagrams (`.excalidraw.svg` is the editable source, `.png` is embedded here). They are generated by `tools/diagrams/build.py`: `cd tools/diagrams && npm install && npm run build`

## References

* [Oracle Cloud Free Tier](https://www.oracle.com/cloud/free/): sign-up and what Always Free and the 30-day trial include
* [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm): limits for compute, storage and networking
* [Site-to-Site VPN Overview](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/overviewIPsec.htm): tunnels, CPE object, BGP or static routing
* [Dynamic Routing Gateways](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingDRGs.htm): DRG attachments, DRG route tables and import distributions
* [Libreswan CPE configuration](https://docs.oracle.com/en-us/iaas/Content/Network/Reference/libreswanCPE.htm): the route-based VTI config this lab is based on
* [Enabling Network Load Balancer Source/Destination Preservation](https://docs.oracle.com/en-us/iaas/Content/NetworkLoadBalancer/NetworkLoadBalancers/preserve-source-id.htm): NLB as a transparent next hop, symmetric hashing
* [VCN Route Tables](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingroutetables.htm#Route): private IP as a route target
* [Security Lists](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securitylists.htm): stateful and stateless subnet rules
* [Overview of Load Balancer](https://docs.oracle.com/en-us/iaas/Content/Balance/Concepts/balanceoverview.htm): the public flexible LB
* [Learn About Deploying Palo Alto firewall in Active/Active mode with OCI Flexible Network Load Balancer](https://docs.oracle.com/en/solutions/oci-nlb-palo-alto-active-active/index.html): the production version of this pattern
* [Is an asymmetric traffic path allowed in OCI?](https://www.ateam-oracle.com/a-routing-scenario-is-an-asymmetric-traffic-path-allowed-in-oci): routing through NVAs
