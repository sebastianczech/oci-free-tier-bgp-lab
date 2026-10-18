# OCI Always Free BGP lab

A BGP and hybrid-networking lab on Oracle Cloud that stays inside the [Always Free](https://www.oracle.com/cloud/free/) limits and uses only the two E2.1.Micro VMs, so it never waits for Ampere A1 capacity. A simulated on-prem data centre (the CPE VM) connects to a hub VCN over a Site-to-Site VPN with BGP, and peers with a hub router VM over eBGP multihop across that VPN. The router serves a web page behind a private Network Load Balancer (for on-prem) and a public Load Balancer (for the internet). The [Azure mapping](#azure-mapping) and [AWS mapping](#aws-mapping) sections list the equivalents.

Everything is vendor-neutral: Ubuntu 24.04, FRR, Libreswan, nginx and iptables. Nothing here needs a licence.

## Topology

![Topology: hub VCN with the public LB, router-1 and the private NLB; on-prem VCN with the CPE; DRG and two IPSec tunnels with BGP; internet and on-prem flows to nginx on router-1](diagrams/topology.png)

*Editable source: [`topology.excalidraw.svg`](diagrams/topology.excalidraw.svg) (open in Excalidraw).*

**Route tables**

| Where | Destination | Next hop | Why |
|---|---|---|---|
| `lb` subnet | 0.0.0.0/0 | Internet gateway | public LB |
| `nva` subnet | 0.0.0.0/0 | Internet gateway | router-1's own traffic (packages, SSH) |
| `nva` subnet | 172.16.0.0/16, 192.168.100.0/24 | DRG | router-1 and the NLB → on-prem |
| DRG attachment (VCN ingress) | *(empty)* | | attached but without rules: the hook for [exercise 5](#exercise-5-make-the-loopbacks-reachable) |
| DRG (auto, BGP) | 172.16.0.0/24, 192.168.100.0/24 | IPSec tunnels | learned from the CPE |

**Not covered on Always Free Micro:** an NVA *in the path*: a router pair behind a transparent NLB with ingress routing and UDR-style route rules. That needs two more VMs, and therefore Ampere A1 capacity. See [Learn About Deploying Palo Alto firewall in Active/Active mode with OCI Flexible Network Load Balancer](https://docs.oracle.com/en/solutions/oci-nlb-palo-alto-active-active/index.html) for that pattern.

## Packet flows

**On-prem → web** (`curl http://10.0.1.100` from the CPE):
1. The CPE has learned the hub subnets 10.0.0.0/24 and 10.0.1.0/24 by BGP from both tunnels, so the packet leaves through `vti1` or `vti2`. The source is 172.16.0.10, because the `SET-SRC` route-map stops Linux from using the 169.254 tunnel address.
2. The OCI VPN headend decrypts the packet and the DRG forwards it to the hub VCN attachment. The attachment's ingress route table is empty, so the packet goes straight to the NLB's subnet.
3. The NLB sends the connection to router-1:80. Source preservation is off, so router-1 sees the NLB's IP (10.0.1.100) as the client, and its reply goes back to the NLB.
4. The NLB reverses the translation and sends the reply to 172.16.0.10: `nva` route → DRG → tunnel → CPE.

**Internet → web** (`curl <app_url>`): the public LB (a full proxy) opens a new connection from its own private IP in `lb` to 10.0.1.11:80. The reply goes back to the LB inside the VCN.

**router-1 → internet**: the `nva` route 0.0.0.0/0 → internet gateway, which maps router-1's private IP to its public IP. No NAT gateway is needed.

## BGP sessions

| Session | Type | Path | What is exchanged |
|---|---|---|---|
| CPE ↔ DRG, ×2 | eBGP 65010 ↔ 31898 over VTI | inside each IPSec tunnel | The CPE advertises 172.16.0.0/24 and 192.168.100.0/24 (prefix-list `ONPREM`). The DRG advertises the hub VCN's subnets (10.0.0.0/24, 10.0.1.0/24), not the VCN CIDR. Every session has an `in` and an `out` route-map (see [Exercises](#exercises)). |
| CPE ↔ router-1 | eBGP multihop 65010 ↔ 65020 | across the VPN, TCP 179 | router-1 advertises its loopback 10.255.0.1/32. The CPE advertises the on-prem prefixes. |

![BGP sessions: CPE to DRG over both tunnels, CPE to router-1 multihop through the VPN; the router's loopback is not reachable because the DRG never learns it](diagrams/bgp-sessions.png)

*Editable source: [`bgp-sessions.excalidraw.svg`](diagrams/bgp-sessions.excalidraw.svg) (open in Excalidraw).*

The second session holds the **key lesson**, which is the same one as in Azure. BGP between VMs only changes the VMs' own routing tables. The CPE learns 10.255.0.1/32, but a ping to it fails: the packet goes into the tunnel, and the DRG has no route for 10.255.0.0/24 because nothing advertised it to OCI. OCI has no equivalent of Azure Route Server or AWS VPC Route Server, so a VM can't program the VCN or DRG with BGP. Only the DRG's own sessions over IPSec or FastConnect do that.

## Always Free usage

| Resource | Used | Always Free limit |
|---|---|---|
| E2.1.Micro | cpe, router-1 | 2 |
| Ampere A1 | **not used** (often "Out of host capacity") | 2 OCPU, 12 GB in total |
| Boot volumes | 2 × 50 GB | 200 GB |
| VCNs | hub, onprem | 2 (Free Tier accounts) |
| Flexible Load Balancer | 1, 10 Mbps | 1 |
| Network Load Balancer | 1 | 1 |
| Site-to-Site VPN | 1 connection, 2 IPSec tunnels | 50 IPSec connections |
| DRG | 1 | Oracle lists no charge for DRG |
| Public IPs | 2 ephemeral (cpe, router-1) | ephemeral IPs on Always Free VMs |
| Flow logs | `nva` subnet | 10 GB/month |
| NAT gateway | **not used** | n/a |

Sources: [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) · [Dynamic Routing Gateway](https://www.oracle.com/cloud/networking/dynamic-routing-gateway/) · [VCN pricing](https://www.oracle.com/cloud/networking/virtual-cloud-network/pricing/)

> ⚠️ **Check after the first apply.** On a Pay-As-You-Go account, anything over the limits above is billed. Look at *Billing → Cost Analysis* the next day, and set a budget alert (for example $1) beforehand. Oracle can reclaim Always Free VMs that stay idle for 7 days, so destroy the lab between sessions.

## Deploy

Prerequisites: an OCI account (the profile's region must be the tenancy's home region), `~/.oci/config` with an API key, Terraform ≥ 1.5, and an SSH key pair. Terraform SSHes to the CPE VM to push the VPN config, so it uses `ssh_private_key_path`. The SSH rules allow only your current public IP, which Terraform reads from `https://ifconfig.me/ip` on every plan.

**Authenticate** (once). The provider reads the `DEFAULT` profile in `~/.oci/config` (`config_file_profile`):

```bash
brew install oci-cli
oci setup config                               # user OCID, tenancy OCID, home region; Y to generate a key pair
cat ~/.oci/oci_api_key_public.pem              # Console → My profile → API keys → Add API key → Paste a public key
oci iam availability-domain list               # test: lists your ADs
```

The user OCID is under *avatar → My profile*, the tenancy OCID under *avatar → Tenancy*. The fingerprint the console shows after the upload must match `fingerprint=` in `~/.oci/config`. Without the CLI, *Add API key → Generate API key pair* downloads the private key and shows a config snippet to paste into `~/.oci/config` (point `key_file=` at the `.pem`). See [Required Keys and OCIDs](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm).

**Find your Micro AD.** In multi-AD regions, Always Free E2.1.Micro VMs work in one availability domain only; elsewhere the limit is 0 and the launch fails with `400-LimitExceeded`. Set `micro_ad_index` to the 0-based position of the AD with value 2:

```bash
oci limits value list --service-name compute --name vm-standard-e2-1-micro-count --all \
  --compartment-id "$(awk -F= '/^tenancy/{print $2}' ~/.oci/config)"
```

**Deploy:**

```bash
cp terraform.tfvars.example terraform.tfvars   # set compartment_id (= tenancy OCID) and micro_ad_index
terraform init
terraform plan
terraform apply                                # ~10-15 min, mostly the VPN and cloud-init
terraform output
```

## Test

```bash
# CPE: tunnels and BGP
ssh ubuntu@<cpe>
sudo ipsec trafficstatus                     # both tunnels with traffic counters
sudo vtysh -c "show bgp summary"             # 2 OCI peers + router-1 Established
sudo vtysh -c "show ip route bgp"            # 10.0.0.0/24, 10.0.1.0/24 via vti1 and vti2 (ECMP), 10.255.0.1/32
curl -s http://10.0.1.100                    # on-prem → NLB → nginx on router-1
curl -s --interface 192.168.100.1 http://10.0.1.100   # from the on-prem "LAN"
ping -c3 10.0.1.11                           # on-prem → router-1 directly
ping -c3 10.255.0.1                          # fails: see "BGP sessions" above

# router-1
ssh ubuntu@<router-1>
sudo vtysh -c "show bgp summary"             # the CPE Established
sudo vtysh -c "show ip route bgp"            # 192.168.100.0/24 via 172.16.0.10; 172.16.0.0/24 "inactive" (its next hop is inside it)
sudo tcpdump -ni any port 80                 # curl from the CPE: the client is 10.0.1.100 (the NLB)

# From your Mac
curl http://<lb-ip>                          # app_url output
```

In the OCI console, *Networking → Site-to-Site VPN → tunnels* shows the IPSec and BGP status. *DRG → DRG route tables → Get all route rules* shows the BGP-learned on-prem routes.

## Exercises

The exercises build on each other but each one ends with a cleanup step, so you can do them in any order. Each one has an **Azure link** and an **AWS link** that names the same decision in those clouds. The expected outputs come from the configs and FRR's documented behaviour; they have not been captured from a live run yet.

Run FRR commands with `sudo vtysh` (or `sudo vtysh -c "<command>"`). In the configs every eBGP neighbor has an `in` and an `out` route-map: with `frr defaults traditional`, FRR applies [RFC 8212](https://datatracker.ietf.org/doc/html/rfc8212) (`bgp ebgp-requires-policy`), so a session without policy is Established but exchanges nothing.

| VM | AS | Neighbors | Accepts (`in`) | Sends (`out`) |
|---|---|---|---|---|
| cpe | 65010 | DRG `169.254.21.1`, `169.254.22.1` (peer-group `OCI`) | `FROM-OCI`: 10.0.0.0/16 and longer | `ONPREM-ONLY`: 172.16.0.0/24, 192.168.100.0/24 |
| cpe | 65010 | router-1 `10.0.1.11` (peer-group `ROUTERS`) | `FROM-ROUTERS`: 10.255.0.1/32 | `ONPREM-ONLY` |
| router-1 | 65020 | cpe `172.16.0.10` | `FROM-CPE`: 172.16.0.0/16, 192.168.100.0/24 and longer | `TO-CPE`: its loopback 10.255.0.1/32 |

### Exercise 1: Sessions and the state machine

On the CPE:

```
show bgp summary
show bgp neighbors 169.254.21.1
show ip route bgp
```

All three neighbors should show a number in `State/PfxRcd` (*Established*): 2 prefixes (the hub subnets 10.0.0.0/24 and 10.0.1.0/24) from each DRG peer and 1 (10.255.0.1/32) from router-1. In `show bgp neighbors 169.254.21.1`, find the remote AS (31898, Oracle's ASN), the hold time, and `External BGP neighbor may be up to 1 hops away`. For `10.0.1.11` the same line says `up to 5 hops` (`ebgp-multihop 5`). `show ip route bgp` shows each hub subnet with two next hops, one per VTI (`maximum-paths 2`).

Break and fix: take one tunnel down and watch its BGP session drop to `Active` while the hub stays reachable over the other one:

```bash
sudo ipsec auto --down oci-tunnel-1
sudo vtysh -c "show bgp summary"           # 169.254.21.1 Active/Connect, 169.254.22.1 still up
curl -s http://10.0.1.100                  # still works through vti2
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

Try the same on the CPE with `no neighbor OCI route-map FROM-OCI in`: the CPE loses the hub routes, and `curl http://10.0.1.100` leaves through the internet gateway instead of the tunnels and fails.

**Azure link:** filter what an NVA accepts from Azure Route Server and what it advertises to it. A missing export filter can push a default route to every VNet that ARS feeds.
**AWS link:** VPC Route Server and Transit Gateway Connect peers are ordinary eBGP sessions. Filter both directions on the appliance.

### Exercise 3: AS path and loop prevention

The CPE learns the hub subnets from the DRG over both tunnels. Let it advertise them back to OCI:

```
# cpe
conf t
ip prefix-list ONPREM permit 10.0.0.0/16 le 24
end
clear bgp 169.254.21.1 soft out
clear bgp 169.254.22.1 soft out
show bgp neighbors 169.254.22.1 advertised-routes
```

The CPE now sends 10.0.0.0/24 and 10.0.1.0/24 to the DRG with path `65010 31898`. In the console, *DRG → DRG route tables → Get all route rules* still shows them only through the VCN attachment, never through a tunnel: the path already contains 31898, the DRG's own ASN, so the DRG treats it as a loop and drops it. FRR has the knob for the receiving side (`neighbor … allowas-in`); cloud gateways don't expose it.

**Azure link:** this is why an NVA can't hand Azure Route Server back a route that ARS learned from the VPN/ER gateway: the path already contains 65515, so ARS drops it.
**AWS link:** the same eBGP rule applies to the Amazon-side ASN of a virtual private gateway or Transit Gateway: a path that already contains it is dropped.

Clean up: `no ip prefix-list ONPREM permit 10.0.0.0/16 le 24` on the CPE, then the two soft clears.

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
  neighbor 169.254.22.1 route-map OCI-T2-OUT out
end
clear bgp 169.254.22.1 soft out
```

In the console, *DRG → DRG route tables → Get all route rules* still lists 172.16.0.0/24 and 192.168.100.0/24, now only through tunnel 1. Run `ping 172.16.0.10` on router-1 and watch `sudo ipsec trafficstatus` on the CPE: only tunnel 1's inbound counter grows. The CPE still sends its own traffic over both tunnels (ECMP). That asymmetry is fine for the DRG; to make tunnel 2 the backup in both directions, also lower `local-preference` for routes learned from 169.254.22.1 with an `in` route-map.

**Azure link:** prepending on one link of an active-active VPN or ExpressRoute is how on-prem picks the primary path into Azure.
**AWS link:** AWS also prefers the shorter AS path when choosing between VPN tunnels, so prepending sets the active tunnel.

Clean up: `neighbor 169.254.22.1 route-map ONPREM-ONLY out`, `no route-map OCI-T2-OUT`, then the soft clear.

### Exercise 5: Make the loopbacks reachable

The CPE has 10.255.0.1/32 in its routing table, but `ping 10.255.0.1` fails (see [BGP sessions](#bgp-sessions)). Advertising 10.255.0.0/24 from the CPE to OCI doesn't help: the DRG would learn it from the tunnel and send it straight back.

Find a configuration that makes `ping -I 192.168.100.1 10.255.0.1` from the CPE work. Hints: which DRG route table decides where the DRG sends traffic for a prefix, can it point at the hub VCN attachment, and what can the attachment's (empty) ingress route table do with a destination that is not a subnet? router-1 will also need `skip_source_dest_check`, because 10.255.0.1 isn't an address OCI assigned to its VNIC. Check the [VCN route table](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingroutetables.htm#Route) rules for private IP targets before you start. Make the change in Terraform (`vpn.tf`, `network.tf`, `compute.tf`), not in the console, so `terraform destroy` still cleans up.

**Azure link:** Azure Route Server learns 10.255.0.1/32 from the NVA over BGP and programs it into the VNet and the VPN gateway, so none of the static work is needed.
**AWS link:** VPC Route Server does the same for VPC route tables (next hop = the appliance's ENI); a Transit Gateway learns it through a Connect attachment.

### Exercise 6: Flow logs

*Logging → Log groups → bgp-lab-logs → nva flow log* shows accepted flows in the router subnet. Run `curl http://10.0.1.100` on the CPE a few times, wait a few minutes, and find two sets of records: 172.16.0.10 → 10.0.1.100:80 (on-prem to the NLB) and 10.0.1.100 → 10.0.1.11:80 (the NLB to router-1, after source translation). Do the same for `curl <app_url>` from your Mac and find the flow from the public LB's private IP in `lb` to 10.0.1.11:80.

**Azure link:** VNet flow logs (the successor to NSG flow logs) record the same flows on the backend's NIC.
**AWS link:** VPC Flow Logs on the target's ENI; with an NLB, the flows show the load balancer's private IP unless client IP preservation is on.

### Exercise 7: Watch BGP on the wire

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
| Private NLB (TCP 80 VIP) | Internal Standard Load Balancer |
| Public flexible Load Balancer | Public Standard Load Balancer (or Application Gateway for L7) |
| Security lists | NSGs |
| No equivalent | Azure Route Server (NVA ↔ fabric BGP) |

* [About active-active mode VPN gateways](https://learn.microsoft.com/en-us/azure/vpn-gateway/about-active-active-gateways): two gateway instances, two tunnels and two BGP peers, like the two OCI tunnels
* [About BGP and VPN Gateway](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-bgp-overview): BGP over S2S VPN, ASN 65515, APIPA peer addresses
* [Modify local network gateway settings using the Azure portal](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-modify-local-network-gateway-portal): the on-prem side (OCI CPE object)
* [About VPN Gateway configuration settings](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings#gwsub): GatewaySubnet rules (UDRs allowed, but no 0.0.0.0/0 and no NSG)
* [Azure virtual network traffic routing](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-udr-overview): UDRs and the *Virtual appliance* next hop
* [What is Azure Load Balancer?](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-overview): internal and public Standard Load Balancer
* [Azure network security groups overview](https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview): stateful rules on subnets and NICs
* [What is Azure Route Server?](https://learn.microsoft.com/en-us/azure/route-server/overview): BGP between NVAs and the VNet, which OCI doesn't have

## AWS mapping

| This lab (OCI) | AWS equivalent |
|---|---|
| DRG + Site-to-Site VPN, BGP | Virtual private gateway or Transit Gateway + Customer gateway + Site-to-Site VPN (two tunnels), BGP |
| VCN ingress route table on the DRG attachment | Gateway route table with an edge association to the virtual private gateway (ingress routing) |
| Private NLB (TCP 80 VIP) | Internal Network Load Balancer |
| Public flexible Load Balancer | Application Load Balancer |
| Security lists (subnet scope, stateful) | Security groups (stateful); network ACLs are subnet scope but stateless |
| No equivalent | VPC Route Server (NVA ↔ VPC route table BGP), or Transit Gateway Connect (GRE + BGP to the TGW) |

* [How AWS Site-to-Site VPN works](https://docs.aws.amazon.com/vpn/latest/s2svpn/how_it_works.html): virtual private gateway, Transit Gateway and customer gateway
* [Tunnel options for your AWS Site-to-Site VPN connection](https://docs.aws.amazon.com/vpn/latest/s2svpn/VPNTunnels.html): two tunnels per connection, inside CIDRs (169.254.x.x/30), IKE settings
* [AWS Site-to-Site VPN customer gateway devices](https://docs.aws.amazon.com/vpn/latest/s2svpn/your-cgw.html): what the CPE has to do, including BGP
* [AWS Site-to-Site VPN attachments in AWS Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/tgw-vpn-attachments.html): VPN terminated on a TGW instead of a VGW
* [Gateway route tables](https://docs.aws.amazon.com/vpc/latest/userguide/gateway-route-tables.html): ingress routing on the virtual private gateway, the DRG attachment ingress route table equivalent
* [What is a Network Load Balancer?](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/introduction.html): the internal L4 load balancer, like the OCI NLB here
* [What is an Application Load Balancer?](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html): the full-proxy HTTP LB, like the OCI public LB
* [Control traffic to your AWS resources using security groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html): stateful, per ENI
* [Control subnet traffic with network access control lists](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html): stateless, per subnet
* [Dynamic routing in your VPC using VPC Route Server](https://docs.aws.amazon.com/vpc/latest/userguide/dynamic-routing-route-server.html): BGP from appliances into VPC route tables, which OCI doesn't have
* [Connect attachments and Connect peers in AWS Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/tgw-connect.html): GRE + BGP between an appliance and a Transit Gateway

## Files

- `network.tf`: VCNs, subnets, route tables, security lists, flow logs
- `vpn.tf`: DRG, CPE, IPSec connection, tunnels (BGP, IKEv2), and the SSH push of the CPE config
- `compute.tf`: the 2 Micro VMs (cpe, router-1)
- `load_balancers.tf`: the private NLB and the public LB, both in front of nginx on router-1
- `templates/`: cloud-init for each VM, plus the Libreswan and FRR config templates for the CPE
- `diagrams/`: Excalidraw diagrams (`.excalidraw.svg` is the editable source, `.png` is embedded here). They are generated by `tools/diagrams/build.py`: `cd tools/diagrams && npm install && npm run build`

## References

* [Oracle Cloud Free Tier](https://www.oracle.com/cloud/free/): sign-up and what Always Free and the 30-day trial include
* [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm): limits for compute, storage and networking
* [Site-to-Site VPN Overview](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/overviewIPsec.htm): tunnels, CPE object, BGP or static routing
* [Dynamic Routing Gateways](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingDRGs.htm): DRG attachments, DRG route tables and import distributions
* [Libreswan CPE configuration](https://docs.oracle.com/en-us/iaas/Content/Network/Reference/libreswanCPE.htm): the route-based VTI config this lab is based on
* [VPN Connection to Google](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/vpn_to_gcp.htm): lists the 169.254.x.x ranges OCI rejects as inside-tunnel IPs
* [VCN Route Tables](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingroutetables.htm#Route): private IP as a route target
* [Security Lists](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securitylists.htm): stateful and stateless subnet rules
* [Overview of Load Balancer](https://docs.oracle.com/en-us/iaas/Content/Balance/Concepts/balanceoverview.htm): the public flexible LB
* [Learn About Deploying Palo Alto firewall in Active/Active mode with OCI Flexible Network Load Balancer](https://docs.oracle.com/en/solutions/oci-nlb-palo-alto-active-active/index.html): the NVA-in-the-path pattern this lab doesn't build on Micro VMs
