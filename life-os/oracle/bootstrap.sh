#!/usr/bin/env bash
# Oracle Cloud Shell only. Tokyo region; conservative Always Free-only provisioner.
set -Eeuo pipefail
REG=ap-tokyo-1
D="$HOME/life-os-setup"
mkdir -p "$D"; chmod 700 "$D"
die(){ echo "STOP: $*" >&2; exit 1; }
command -v oci >/dev/null || die 'Use the Oracle Cloud Shell terminal.'
command -v jq >/dev/null || die 'jq required.'
# Oracle Cloud Shell uses /etc/oci/config and a region-named profile;
# unlike a local CLI install, Cloud Shell normally has no [DEFAULT] profile.
CFG="${OCI_CLI_CONFIG_FILE:-/etc/oci/config}"
PROFILE="${OCI_CLI_PROFILE:-ap-tokyo-1}"
T="${OCI_CLI_TENANCY:-${OCI_TENANCY_OCID:-}}"
if [[ "$T" != ocid1.tenancy.* ]]; then
 T="$(awk -v profile="$PROFILE" '
  /^\[[^]]+\]/ {
    section=$0; sub(/^\[/,"",section); sub(/\].*$/,"",section)
    active=(section==profile)
    next
  }
  active && /^[[:space:]]*tenancy[[:space:]]*=/ {
    sub(/^[^=]*=/,""); gsub(/[[:space:]]/,"");print;exit
  }' "$CFG" 2>/dev/null || true)"
fi
[[ "$T" == ocid1.tenancy.* ]] || die "Cannot read tenancy from Cloud Shell profile '$PROFILE' in '$CFG'. No resources created."
echo 'Oracle Cloud Shell tenancy resolved successfully.'
oci iam availability-domain list --region "$REG" --compartment-id "$T" > "$D/ads.json" || die 'OCI authentication/Tokyo access failed.'
jq -e '.data|length>0' "$D/ads.json" >/dev/null || die 'No available domains.'
oci iam compartment list --region "$REG" --compartment-id "$T" --compartment-id-in-subtree true --all > "$D/comp.json" || die 'Cannot audit compartments.'
for C in $(jq -r --arg root "$T" '$root, (.data[]|select(."lifecycle-state"=="ACTIVE")|.id)' "$D/comp.json" | sort -u); do
 oci compute instance list --region "$REG" --compartment-id "$C" --all > "$D/vms.json" || die 'VM audit failed.'
 jq -e '[.data[]|select(."lifecycle-state"!="TERMINATED")]|length==0' "$D/vms.json" >/dev/null || die 'Existing VM found: free compute usage cannot be guaranteed.'
 oci bv volume list --region "$REG" --compartment-id "$C" --all > "$D/volumes.json" || die 'Volume audit failed.'
 jq -e '[.data[]|select(."lifecycle-state"!="TERMINATED")]|length==0' "$D/volumes.json" >/dev/null || die 'Existing block volumes found.'
 for AD in $(jq -r '.data[].name' "$D/ads.json"); do
  oci bv boot-volume list --region "$REG" --compartment-id "$C" --availability-domain "$AD" --all > "$D/boot.json" || die 'Boot volume audit failed.'
  jq -e '[.data[]|select(."lifecycle-state"!="TERMINATED")]|length==0' "$D/boot.json" >/dev/null || die 'Existing boot volume found.'
 done
done
oci compute image list --region "$REG" --compartment-id "$T" --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC --all > "$D/images.json" || die 'Unable to list A1 Ubuntu images.'
IMG="$(jq -r '[.data[]|select(."lifecycle-state"=="AVAILABLE" and (."display-name"|test("Ubuntu-24.04.*aarch64";"i")))]|.[0].id//empty' "$D/images.json")"
[[ "$IMG" == ocid1.image.* ]] || die 'No Ubuntu 24.04 ARM image: stopped.'
oci network vcn list --region "$REG" --compartment-id "$T" --all > "$D/vcns.json" || die 'Cannot inspect VCNs.'
VCN="$(jq -r '[.data[]|select(."display-name"=="life-os-vcn" and ."lifecycle-state"=="AVAILABLE")]|.[0].id//empty' "$D/vcns.json")"
# Oracle Cloud Shell may enforce FIPS mode, which rejects ED25519 key generation.
# RSA-4096 is permitted in FIPS mode and works with Ubuntu OpenSSH.
K="$HOME/.ssh/life-os-rsa4096"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if [[ ! -e "$K" && ! -e "$K.pub" ]]; then
 ssh-keygen -q -t rsa -b 4096 -f "$K" -N '' -C life-os || die 'RSA-4096 key generation failed.'
fi
[[ -s "$K" && -s "$K.pub" ]] || die 'RSA key pair is incomplete; refusing to overwrite it.'
chmod 600 "$K"; chmod 644 "$K.pub"
ssh-keygen -y -f "$K" >/dev/null || die 'RSA private key integrity check failed.'
echo 'Preparing isolated life-os subnet: no public inbound management ports.'
if [[ -z "$VCN" ]]; then
 VCN="$(oci network vcn create --region "$REG" --compartment-id "$T" --display-name life-os-vcn --cidr-blocks '["10.42.0.0/16"]' --dns-label lifeos --wait-for-state AVAILABLE --query data.id --raw-output)"
else
 echo 'Reusing previously created life-os VCN.'
 oci network vcn get --region "$REG" --vcn-id "$VCN" > "$D/vcn.json"
 jq -e '.data."cidr-blocks"|index("10.42.0.0/16")!=null' "$D/vcn.json" >/dev/null || die 'Existing VCN CIDR mismatch.'
fi
[[ "$VCN" == ocid1.vcn.* ]] || die 'VCN failed.'
# Do not mutate the VCN's shared default route table or default security list.
# SSH is permitted only from inside this VCN (for OCI Cloud Shell Private Networking).
# There is no ingress rule allowing 0.0.0.0/0 to port 22.
oci network internet-gateway list --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --all > "$D/igs.json" || die 'Cannot list gateways.'
IG="$(jq -r '[.data[]|select(."display-name"=="life-os-ig" and ."lifecycle-state"=="AVAILABLE")]|.[0].id//empty' "$D/igs.json")"
if [[ -z "$IG" ]]; then
 IG="$(oci network internet-gateway create --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --is-enabled true --display-name life-os-ig --wait-for-state AVAILABLE --query data.id --raw-output)" || die 'Gateway creation failed.'
fi
[[ "$IG" == ocid1.internetgateway.* ]] || die 'Invalid gateway identifier.'
oci network route-table list --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --all > "$D/rts.json" || die 'Route-table list failed.'
RT="$(jq -r '[.data[]|select(."display-name"=="life-os-route" and ."lifecycle-state"=="AVAILABLE")]|.[0].id//empty' "$D/rts.json")"
ROUTES="$(jq -cn --arg ig "$IG" '[{cidrBlock:"0.0.0.0/0",networkEntityId:$ig}]')"
if [[ -z "$RT" ]]; then
 RT="$(oci network route-table create --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --display-name life-os-route --route-rules "$ROUTES" --wait-for-state AVAILABLE --query data.id --raw-output)" || die 'Route-table creation failed.'
else
 oci network route-table get --region "$REG" --rt-id "$RT" > "$D/route.json" || die 'Cannot inspect dedicated route table.'
 jq -e --arg ig "$IG" '[.data."route-rules"[]|select(."cidr-block"=="0.0.0.0/0" and ."network-entity-id"==$ig)]|length==1' "$D/route.json" >/dev/null || die 'Dedicated route table differs; refusing to overwrite.'
fi
[[ "$RT" == ocid1.routetable.* ]] || die 'Invalid route-table identifier.'
oci network security-list list --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --all > "$D/sls.json" || die 'Security-list list failed.'
SL="$(jq -r '[.data[]|select(."display-name"=="life-os-private-ssh" and ."lifecycle-state"=="AVAILABLE")]|.[0].id//empty' "$D/sls.json")"
INGRESS='[{"source":"10.42.0.0/16","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}}]'
EGRESS='[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]'
if [[ -z "$SL" ]]; then
 SL="$(oci network security-list create --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --display-name life-os-private-ssh --ingress-security-rules "$INGRESS" --egress-security-rules "$EGRESS" --wait-for-state AVAILABLE --query data.id --raw-output)" || die 'Security-list creation failed.'
fi
[[ "$SL" == ocid1.securitylist.* ]] || die 'Invalid security-list identifier.'
oci network security-list get --region "$REG" --security-list-id "$SL" > "$D/security.json" || die 'Cannot inspect dedicated security list.'
# Refuse unexpected ingress or SSH open to the public; this is safer than silently changing rules.
jq -e '[.data."ingress-security-rules"[]] | length == 1 and
 (.[0].source=="10.42.0.0/16") and (.[0].protocol=="6") and
 (.[0]."tcp-options"."destination-port-range".min==22) and
 (.[0]."tcp-options"."destination-port-range".max==22)' "$D/security.json" >/dev/null || die 'Unexpected ingress rules in dedicated security list.'
oci network subnet list --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --all > "$D/subnets.json" || die 'Subnet listing failed.'
SUB="$(jq -r '[.data[]|select(."display-name"=="life-os-subnet" and ."lifecycle-state"=="AVAILABLE")]|.[0].id//empty' "$D/subnets.json")"
SLIDS="$(jq -cn --arg id "$SL" '[$id]')"
if [[ -z "$SUB" ]]; then
 SUB="$(oci network subnet create --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --cidr-block 10.42.1.0/24 --display-name life-os-subnet --dns-label subnet --prohibit-public-ip-on-vnic false --route-table-id "$RT" --security-list-ids "$SLIDS" --wait-for-state AVAILABLE --query data.id --raw-output)" || die 'Subnet creation failed.'
else
 oci network subnet get --region "$REG" --subnet-id "$SUB" > "$D/subnet.json" || die 'Cannot inspect existing subnet.'
 jq -e '.data."cidr-block"=="10.42.1.0/24" and .data."vcn-id"!=null and .data."prohibit-public-ip-on-vnic"==false' "$D/subnet.json" >/dev/null || die 'Existing subnet does not match expected configuration.'
 # This script has already stopped if any VM or volume exists; avoid shared-default VCN edits.
 oci network subnet update --region "$REG" --subnet-id "$SUB" --route-table-id "$RT" --security-list-ids "$SLIDS" --force >/dev/null || die 'Isolated subnet configuration failed.'
fi
[[ "$SUB" == ocid1.subnet.* ]] || die 'Subnet failed.'
oci network subnet get --region "$REG" --subnet-id "$SUB" > "$D/subnet-final.json" || die 'Cannot verify subnet.'
jq -e --arg rt "$RT" --arg sl "$SL" '.data."route-table-id"==$rt and .data."security-list-ids"==[$sl]' "$D/subnet-final.json" >/dev/null || die 'Subnet isolation not confirmed.'
echo 'Subnet verified: SSH only from the private VCN range; no internet ingress rules.'
# OS first-boot provisioning; no credentials, VPN tokens, or ChatGPT cookies embedded.
# Cloud-init runs independently of the VM RUNNING state. Verify cloud-init separately.
cat > "$D/cloud-init.yaml" <<'CLOUDINIT'
#cloud-config
package_update: true
packages:
  - docker.io
  - snapd
  - xvfb
runcmd:
  - [ systemctl, enable, --now, docker ]
  - [ snap, install, chromium ]
  - [ bash, -lc, "uname -m > /var/log/life-os-arm64-check.log; docker --version > /var/log/life-os-docker-check.log; /snap/bin/chromium --version > /var/log/life-os-chromium-check.log" ]
CLOUDINIT
# Try requested 2 OCPU/12GB first, then smaller 1 OCPU/6GB, both A1 Always Free.
# Do not try paid shapes and never retry non-capacity errors.
ID=''
CHOSEN=''
for SPEC in '2:12' '1:6'; do
 OCPU="${SPEC%%:*}"
 RAM="${SPEC##*:}"
 CONFIG="$(jq -cn --argjson cpu "$OCPU" --argjson memory "$RAM" '{ocpus:$cpu,memoryInGBs:$memory}')"
 for AD in $(jq -r '.data[].name' "$D/ads.json"); do
  echo "Trying Always Free VM.Standard.A1.Flex ${OCPU} OCPU/${RAM}GB in $AD"
  if J="$(oci compute instance launch --region "$REG" --compartment-id "$T" --availability-domain "$AD" --display-name life-os --shape VM.Standard.A1.Flex --shape-config "$CONFIG" --image-id "$IMG" --boot-volume-size-in-gbs 50 --subnet-id "$SUB" --assign-public-ip true --ssh-authorized-keys-file "$K.pub" --user-data-file "$D/cloud-init.yaml" 2>"$D/launch.err")"; then
   ID="$(jq -r '.data.id//empty' <<< "$J")"
   CHOSEN="${OCPU} OCPU / ${RAM}GB"
   break
  fi
  if ! grep -Eiq 'out.?of.?host.?capacity|capacity' "$D/launch.err"; then cat "$D/launch.err" >&2; die 'Non-capacity launch error: no fallback.'; fi
 done
 [[ "$ID" == ocid1.instance.* ]] && break
done
[[ "$ID" == ocid1.instance.* ]] || die 'No A1 capacity at 2/12 or 1/6. Paid VM not attempted. The existing VCN may remain.'
echo "$ID" > "$D/instance-ocid"
oci compute instance get --region "$REG" --instance-id "$ID" --wait-for-state RUNNING > "$D/instance.json" || die 'VM created, RUNNING not confirmed.'
VN="$(oci compute vnic-attachment list --region "$REG" --compartment-id "$T" --instance-id "$ID" --query 'data[0]."vnic-id"' --raw-output)"
IP="$(oci network vnic get --region "$REG" --vnic-id "$VN" --query 'data."public-ip"' --raw-output)"
printf '\nCREATED RUNNING: %s\nShape: %s\nIP: %s\nKey: %s\nTo connect: ssh -i %s ubuntu@%s\n' "$ID" "$CHOSEN" "$IP" "$K" "$K" "$IP"
printf 'Cloud-init requested Docker, snap Chromium, and Xvfb. RUNNING does not prove successful installation.\nCloud Shell Private Networking is required for SSH; internet ingress is disabled. Web Bridge is NOT deployed.\n'
