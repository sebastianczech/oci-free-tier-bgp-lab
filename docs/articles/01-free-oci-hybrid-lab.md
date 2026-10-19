# A free hybrid-networking lab on Oracle Cloud

*Part 1 of 5 in the OCI Always Free BGP lab series. Next: [Site-to-Site VPN with Libreswan](02-site-to-site-vpn-libreswan.md).*

Hybrid networking is hard to learn from slides. You need a cloud gateway, an on-prem router, a VPN between them and BGP on top, and in most clouds that costs money every hour it runs. Oracle Cloud's Always Free tier includes everything needed for that: a Dynamic Routing Gateway (DRG), Site-to-Site VPN, a load balancer, a network load balancer and two small VMs.

This series uses one Terraform module, [oci-free-tier-bgp-lab](../../README.md), to build that lab. This first part covers what gets built, why it is built that way, and how to deploy it. The next parts go layer by layer:

1. **A free hybrid-networking lab on Oracle Cloud** (this article)
2. [Site-to-Site VPN with Libreswan: route-based IPSec to a DRG](02-site-to-site-vpn-libreswan.md)
3. [BGP hands-on: eBGP between on-prem and the cloud](03-bgp-hands-on.md)
4. [DRG routing and the missing Route Server](04-drg-routing-no-route-server.md)
5. [Load balancers in a hybrid setup: public LB vs private NLB](05-load-balancers-hybrid.md)

Every article maps the OCI pieces to their Azure and AWS equivalents, so the lessons carry over.

## What gets built

![Topology: hub VCN with the public LB, router-1 and the private NLB; a second VCN plays on-prem with the CPE VM; DRG and two IPSec tunnels with BGP](../../diagrams/topology.png)

- **hub VCN** (10.0.0.0/16): the "cloud". The `lb` subnet holds the public load balancer. The `nva` subnet holds router-1 and the private NLB.
- **router-1** (10.0.1.11): an E2.1.Micro VM with FRR (BGP, AS 65020) and nginx. Its loopback 10.255.0.1/32 plays a network that lives behind a router.
- **onprem VCN** (172.16.0.0/16): a second VCN that plays the on-prem data centre. It has one VM, the **cpe** (172.16.0.10), with Libreswan for IPSec and FRR for BGP (AS 65010). A loopback, 192.168.100.1/24, plays the office LAN.
- **DRG + Site-to-Site VPN**: two IPSec tunnels from the cpe to OCI, with one eBGP session inside each. The DRG is AS 31898, Oracle's ASN.
- **Public LB** (flexible, 10 Mbps) for the internet and **private NLB** (10.0.1.100) for on-prem, both in front of nginx on router-1.

The on-prem side is a VCN in the same tenancy, but the cpe treats it like a real site: its traffic to OCI goes over the internet, through the IPSec tunnels, and the DRG learns the on-prem prefixes only from BGP.

## Staying inside Always Free

| Resource | Used | Always Free limit |
|---|---|---|
| E2.1.Micro | cpe, router-1 | 2 |
| Boot volumes | 2 × 50 GB | 200 GB |
| VCNs | hub, onprem | 2 (Free Tier accounts) |
| Flexible Load Balancer | 1, 10 Mbps | 1 |
| Network Load Balancer | 1 | 1 |
| Site-to-Site VPN | 1 connection, 2 tunnels | 50 IPSec connections |
| DRG | 1 | Oracle lists no charge for DRG |
| Flow logs | `nva` subnet | 10 GB/month |

A few choices follow from these limits:

- **Only the two Micro VMs.** Always Free also includes Ampere A1 capacity, but A1 launches often fail with "Out of host capacity". Two Micro VMs always start, so the lab uses only those. That's why nginx runs on router-1 instead of a separate app VM.
- **No NAT gateway.** It isn't free. The VMs have ephemeral public IPs and use the internet gateway.
- **Destroy between sessions.** Oracle can reclaim Always Free VMs that stay idle for 7 days, and nothing in the lab needs to persist.

On a Pay-As-You-Go account, anything over the limits is billed. Set a budget alert (for example $1) before the first apply, and look at *Billing → Cost Analysis* the next day.

## Design notes

**Fixed private IPs.** Every VM has a fixed private IP (`local.ip` in `main.tf`). That lets Terraform write the BGP neighbors and route tables before the VMs exist.

**The CPE config is pushed over SSH, not cloud-init.** router-1 gets its FRR config from cloud-init. The cpe can't: its IPSec config needs the OCI tunnel endpoints and pre-shared keys, and those exist only after the IPSec connection exists, which needs the cpe's public IP first. Terraform breaks the loop with `terraform_data.cpe_config` in `vpn.tf`: once the VPN exists, it copies the Libreswan and FRR configs to the cpe over SSH and restarts both services.

**Oracle's Ubuntu images have their own firewall.** They ship iptables rules that REJECT all inbound traffic except SSH. Each cloud-init removes the INPUT and FORWARD REJECT rules, and the security lists do the filtering instead. There is a second rule that matters later: the `InstanceServices` chain rejects TCP and UDP from the VM to 169.254.0.0/16, to protect the metadata service. The BGP peers inside the tunnels also use 169.254.x.x addresses, so the cpe allows output on its tunnel interfaces. [Part 2](02-site-to-site-vpn-libreswan.md) has an exercise on this.

**The Minimal image has no `ping`.** Cloud-init installs `iputils-ping`, `tcpdump` and `traceroute` where they're needed.

## Deploy

You need an OCI account, Terraform 1.5 or later, an SSH key pair, and an API key in `~/.oci/config`. The [README](../../README.md#deploy) has the step-by-step setup. Two things trip people up:

- **Home region.** Always Free compute only works in the tenancy's home region, so the `~/.oci/config` profile must point there.
- **The Micro availability domain.** In regions with several availability domains, E2.1.Micro VMs work in one of them only. Set `micro_ad_index` to the AD where the `vm-standard-e2-1-micro-count` limit is 2 (the README shows the `oci limits` command).

```bash
cp terraform.tfvars.example terraform.tfvars   # compartment_id and micro_ad_index
terraform init
terraform apply                                # about 10-15 minutes
terraform output
```

## Smoke test

```bash
ssh ubuntu@<cpe>
sudo ipsec trafficstatus                     # both tunnels, with traffic counters
sudo vtysh -c "show bgp summary"             # 2 DRG peers + router-1 Established
curl -s http://10.0.1.100                    # on-prem → NLB → nginx on router-1
```

From your laptop, `curl <app_url>` reaches the same nginx through the public LB. If all four work, the lab is ready for the next parts.

Destroy it when you're done:

```bash
terraform destroy
```

## Azure and AWS equivalents

| This lab (OCI) | Azure | AWS |
|---|---|---|
| DRG + Site-to-Site VPN, BGP | VPN Gateway (active-active) + Local Network Gateway | Virtual private gateway or Transit Gateway + Customer gateway |
| VCN | VNet | VPC |
| Security lists | NSGs | Security groups / network ACLs |
| Private NLB | Internal Standard Load Balancer | Internal Network Load Balancer |
| Public flexible LB | Public Load Balancer or Application Gateway | Application Load Balancer |

## Links

* [Oracle Cloud Free Tier](https://www.oracle.com/cloud/free/): sign-up and what Always Free includes
* [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm): limits for compute, storage and networking
* [Dynamic Routing Gateway](https://www.oracle.com/cloud/networking/dynamic-routing-gateway/): DRG pricing
* [Required Keys and OCIDs](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm): the API key Terraform uses
* [OCI Architecture Diagram Toolkits](https://docs.oracle.com/en-us/iaas/Content/General/Reference/graphicsfordiagrams.htm): the official icons used in the diagrams
