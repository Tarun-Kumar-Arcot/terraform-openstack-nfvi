# terraform-openstack-nfvi

Terraform configuration for provisioning multi-tenant logical network segments on an OpenStack NFVI fabric using the Neutron Networking API. Designed for VIM (Virtualized Infrastructure Manager) environments following ETSI NFV architecture patterns.

Includes a full local development setup guide using LXD + DevStack on Fedora Linux.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  jarvis (Fedora 42)  ·  host IP: <HOST_IP>                    │
│                                                                  │
│       ┌──────────────────────────────────┐                       │
│       │           Terraform              │                       │
│       │   openstack provider v2.0        │                       │
│       │         main.tf                  │                       │
│       └─────────────┬────────────────────┘                       │
└─────────────────────┼────────────────────────────────────────────┘
                      │ HTTP/REST via lxdbr0 bridge
┌─────────────────────┼────────────────────────────────────────────┐
│  devstack-vm (Ubuntu 24.04)  ·  <DEVSTACK_VM_IP>                   │
│                      │                                           │
│   ┌──────────────────┼───────────────────────────────────────┐   │
│   │  ┌─────────┐     │   ┌──────────┐        ┌───────────┐   │   │
│   │  │Keystone │ ────┤──▶│ Neutron  │───────▶│  OVN+OVS  │   │   │
│   │  │  (1)    │     │   │   (2)    │        │    (3)    │   │   │
│   │  │Identity │     │   │ ML2/OVN  │        │ Data plane│   │   │
│   │  └─────────┘     │   └──────────┘        └───────────┘   │   │
│   └──────────────────┼───────────────────────────────────────┘   │
└─────────────────────┼────────────────────────────────────────────┘
                      │
           ┌──────────┴──────────┐
           │                     │
┌──────────────────┐   ┌──────────────────┐
│tenant-alpha-net  │   │ tenant-beta-net  │
│ VNI: 10100       │   │ VNI: 10200       │
│ 10.100.10.0/24   │   │ 10.200.10.0/24   │
│ VRF_ALPHA        │   │ VRF_BETA         │
└──────────────────┘   └──────────────────┘
```

### Components

| Component | Role | Details |
|---|---|---|
| **Terraform** | IaC control plane | Runs on jarvis host. Reads `main.tf`, calls OpenStack provider, records state in `terraform.tfstate` |
| **LXD bridge (lxdbr0)** | Virtual network | Connects jarvis host to devstack-vm at `<LXD_BRIDGE_SUBNET>`. Provides NAT for outbound internet from VM |
| **Keystone** | Identity service `(1)` | Validates credentials (`admin/admin123`, domain `Default`, region `RegionOne`). Returns an auth token for all subsequent API calls |
| **Neutron** | Networking API `(2)` | Accepts REST calls to create/list/delete networks and subnets. Uses ML2 plugin with OVN as the mechanism driver. Persists resource records to MariaDB |
| **OVN + OVS** | Data plane `(3)` | Open Virtual Network programs Open vSwitch with Geneve-encapsulated flows. Translates Neutron's logical network model into actual packet forwarding rules in the Northbound/Southbound databases |
| **Tenant networks** | Output | Two isolated NFVI segments with explicit VNI assignments. DHCP disabled — IP assignment is managed externally by the MANO layer |

### Data flow

When you run `terraform apply`, the following sequence happens:

```
1.  Terraform reads provider block → credentials, auth_url, region
2.  POST /identity/v3/auth/tokens   → Keystone validates credentials
3.  Keystone returns X-Auth-Token header
4.  POST /v2.0/networks             → Neutron creates tenant-enterprise-alpha-net
    body: { network_type: geneve, segmentation_id: 10100 }
5.  POST /v2.0/networks             → Neutron creates tenant-enterprise-beta-net
    body: { network_type: geneve, segmentation_id: 10200 }
6.  Neutron ML2/OVN driver → OVN Northbound DB creates logical switch per network
7.  OVN Southbound DB programs OVS flows on each compute node
8.  POST /v2.0/subnets × 2         → Neutron creates subnets with CIDRs
9.  Neutron returns UUIDs for all 4 resources
10. Terraform writes UUIDs to terraform.tfstate
11. Output block prints allocated_vim_segments map
```

### Why Geneve instead of VXLAN

The original Terraform file used `network_type = "vxlan"`. OpenStack with OVN as the mechanism driver uses Geneve as its tunnel encapsulation protocol. OVN does not support the legacy ML2/OVS VXLAN type driver. The segmentation IDs (VNIs), CIDR allocation, and all other behaviour are identical — only the encapsulation protocol label changes.

This reflects Red Hat's product direction: RHOSP 17.1 is the last release supporting ML2/OVS. RHOSO 18.0 (Red Hat OpenStack Services on OpenShift) mandates OVN exclusively.

---

## What This Provisions

Two isolated tenant network segments with explicit VNI assignments:

| Tenant | Segment ID | VRF | CIDR |
|---|---|---|---|
| tenant-enterprise-alpha | 10100 | VRF_ALPHA | 10.100.10.0/24 |
| tenant-enterprise-beta | 10200 | VRF_BETA | 10.200.10.0/24 |

Each tenant gets a dedicated Neutron network (Geneve encapsulation, OVN-backed) and a subnet with DHCP disabled — appropriate for NFVI data plane segments managed externally by a MANO layer.

---

## Repository Structure

```
terraform-openstack/
├── main.tf        # Provider, variables, network/subnet resources, outputs
├── README.md
└── .gitignore
```

---

## Prerequisites

### System Requirements (Local Dev)
- Fedora Linux (tested on Fedora 42)
- At least 8 GB RAM available
- At least 30 GB free disk space
- KVM support: `ls /dev/kvm` must return the device
- LXD installed via snap

### Tools Required
- Terraform >= 1.5.0
- LXD >= 5.x (snap)
- OpenStack CLI (installed inside DevStack VM)

---

## Part 1 — Local OpenStack Setup (LXD + DevStack)

### 1.1 Install and Configure LXD

```bash
# Add yourself to the lxd group (no sudo for lxd commands)
sudo usermod -aG lxd $USER
newgrp lxd

# Start the LXD snap service
sudo snap start lxd

# Verify LXD is accessible
lxc list
```

### 1.2 Check Existing LXD Config

```bash
lxc storage list
lxc network list
lxc profile show default
```

If `lxdbr0` bridge and `default` storage pool already exist, skip `lxd init`. Otherwise:

```bash
cat <<EOF | lxd init --preseed
config: {}
networks:
- name: lxdbr0
  type: bridge
  config:
    ipv4.address: <HOST_IP>/24
    ipv4.nat: "true"
    ipv6.address: none
storage_pools:
- name: default
  driver: dir
profiles:
- name: default
  devices:
    eth0:
      name: eth0
      network: lxdbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
EOF
```

### 1.3 Create Ubuntu 24.04 VM

DevStack master (2026.x) requires Ubuntu 24.04 (noble). Ubuntu 22.04 is no longer in the supported distro list.

```bash
# Verify KVM is available
ls /dev/kvm

# Launch VM
lxc launch ubuntu:24.04 devstack-vm --vm \
  --config limits.cpu=4 \
  --config limits.memory=8GiB

# Set disk size (thin-provisioned — won't consume 28 GiB immediately)
lxc config device override devstack-vm root size=28GiB

# Wait for boot
sleep 30 && lxc list devstack-vm
```

### 1.4 Assign Static IP to VM

The LXD bridge IP range is `<LXD_BRIDGE_SUBNET>`. Assign a static IP inside the VM:

```bash
lxc exec devstack-vm -- bash -c "cat > /etc/netplan/99-static.yaml << 'EOF'
network:
  version: 2
  ethernets:
    enp5s0:
      dhcp4: false
      addresses:
        - <DEVSTACK_VM_IP>/24
      routes:
        - to: default
          via: <HOST_IP>
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF"

lxc exec devstack-vm -- chmod 600 /etc/netplan/99-static.yaml
lxc exec devstack-vm -- netplan apply

# Verify — IPV4 column should show <DEVSTACK_VM_IP>
lxc list devstack-vm
```

### 1.5 Set Up DevStack Inside the VM

```bash
# Enter VM
lxc exec devstack-vm -- bash

# Create stack user (DevStack must not run as root)
useradd -s /bin/bash -d /opt/stack -m stack
echo "stack ALL=(ALL) NOPASSWD: ALL" | tee /etc/sudoers.d/stack
chmod 440 /etc/sudoers.d/stack

# Install git
apt-get update -q && apt-get install -y git

# Switch to stack user
su - stack
```

### 1.6 Clone DevStack and Write local.conf

```bash
git clone https://opendev.org/openstack/devstack /opt/stack/devstack
cd /opt/stack/devstack

cat > local.conf << 'EOF'
[[local|localrc]]
ADMIN_PASSWORD=admin123
DATABASE_PASSWORD=admin123
RABBIT_PASSWORD=admin123
SERVICE_PASSWORD=admin123

HOST_IP=<DEVSTACK_VM_IP>

# Disable unused services to reduce RAM and install time
disable_service tempest
disable_service s-proxy s-object s-container s-account
disable_service cinder c-sch c-api c-vol
disable_service horizon

# Disable legacy ML2/OVS agents — OVN replaces all of these
# q-agt conflicts with OVN and will cause stack.sh to fail
disable_service q-agt q-dhcp q-l3 q-meta

# OVN-based Neutron (DevStack master default)
enable_service neutron q-svc

NEUTRON_CREATE_INITIAL_NETWORKS=False

[[post-config|/etc/neutron/plugins/ml2/ml2_conf.ini]]
[ml2]
type_drivers = flat,vlan,geneve,vxlan
tenant_network_types = geneve
mechanism_drivers = ovn

[ml2_type_geneve]
vni_ranges = 10000:20000

[ml2_type_vxlan]
vni_ranges = 10000:20000
EOF

./stack.sh
```

Install takes 20–40 minutes. Successful completion shows:

```
Keystone is serving at http://<DEVSTACK_VM_IP>/identity/
stack.sh completed in XXX seconds.
```

---

## Part 2 — Terraform Setup

### 2.1 Install Terraform on Fedora

```bash
sudo dnf config-manager addrepo \
  --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install terraform -y
terraform version
```

### 2.2 Verify Connectivity to OpenStack API

```bash
ping -c 3 <DEVSTACK_VM_IP>
curl -s http://<DEVSTACK_VM_IP>/identity/v3 | python3 -m json.tool | head -10
```

The curl should return a JSON `version` block confirming Keystone is reachable from the host.

### 2.3 Provider Configuration

The provider block targets your local DevStack instance:

```hcl
provider "openstack" {
  auth_url    = "http://<DEVSTACK_VM_IP>/identity/v3"
  region      = "RegionOne"
  user_name   = "admin"
  password    = "admin123"   # Local DevStack only. Use OS_PASSWORD env var in production.
  tenant_name = "admin"
  domain_name = "Default"
  insecure    = true
}
```

> **Note:** For production environments, credentials must never be hardcoded. Use `OS_*` environment variables or a `clouds.yaml` file instead.

---

## Part 3 — Running Terraform

```bash
cd terraform-openstack/

# Download OpenStack provider (~2.x)
terraform init

# Validate HCL syntax
terraform validate

# Save plan to file (best practice for approval gates)
terraform plan -out=tfplan

# Apply saved plan
terraform apply tfplan
```

---

## Part 4 — Verification

### From Terraform

```bash
terraform state list
terraform show
terraform output allocated_vim_segments
```

### From OpenStack CLI

```bash
lxc exec devstack-vm -- bash
source /opt/stack/devstack/openrc admin admin

openstack network list
openstack network show tenant-enterprise-alpha-net
openstack network show tenant-enterprise-beta-net
openstack subnet list
```

### Expected State

Both networks should show:

```
| provider:network_type     | geneve  |
| provider:segmentation_id  | 10100   |
| status                    | ACTIVE  |
```

---

## Part 5 — Teardown

```bash
# Destroy all Terraform-managed resources
terraform destroy

# Stop DevStack (inside VM)
lxc exec devstack-vm -- bash -c "su - stack -c 'cd /opt/stack/devstack && ./unstack.sh'"

# Delete the VM entirely
lxc delete devstack-vm --force
```

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `FORCE=yes` required | Ubuntu 22.04 dropped from DevStack master supported distros | Recreate VM with `lxc launch ubuntu:24.04` |
| `q-agt must be disabled with OVN` | Legacy OVS agent conflicts with OVN default | Add `disable_service q-agt q-dhcp q-l3 q-meta` to `local.conf`, run `./unstack.sh` then retry |
| VM has no IPv4 | LXD DHCP unreliable for VMs; Ubuntu 24.04 uses systemd-networkd | Apply static IP via netplan (see Section 1.4). Never run `dhclient` manually |
| `Pool source cannot be changed` | LXD already initialised from previous setup | Skip `lxd init` — check `lxc storage list` and `lxc network list` instead |
| `Permission denied` on LXD socket | Wrong — do not use `sudo` with lxd/lxc | `sudo usermod -aG lxd $USER && newgrp lxd` |
| `flag needs an argument: -out` | `-out` requires a filename argument | Use `terraform plan -out=tfplan` |

---

## References

- [DevStack Documentation](https://docs.openstack.org/devstack/latest/)
- [Terraform OpenStack Provider](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest)
- [Red Hat OpenStack Services on OpenShift 18.0](https://docs.redhat.com/en/documentation/red_hat_openstack_services_on_openshift/18.0)
- [OVN Architecture](https://docs.ovn.org/en/latest/topics/architecture.html)
