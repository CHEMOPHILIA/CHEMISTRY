#!/usr/bin/env bash
# Oracle Cloud Shell only. Tokyo region; conservative Always Free-only provisioner.
set -Eeuo pipefail
REG=ap-tokyo-1
D="$HOME/life-os-setup"
mkdir -p "$D"; chmod 700 "$D"
die(){ echo "STOP: $*" >&2; exit 1; }
command -v oci >/dev/null || die 'Use the Oracle Cloud Shell terminal.'
command -v jq >/dev/null || die 'jq required.'
T="$(awk '/^\[DEFAULT\]/{a=1;next} /^\[/{a=0} a && /^tenancy[[:space:]]*=/{sub(/^[^=]*=/,"");gsub(/[[:space:]]/,"");print;exit}' "$HOME/.oci/config" 2>/dev/null || true)"
[[ "$T" == ocid1.tenancy.* ]] || die 'Tenancy not found in Cloud Shell OCI config.'
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
jq -e '[.data[]|select(."display-name"=="life-os-vcn" and ."lifecycle-state"!="TERMINATED")]|length==0' "$D/vcns.json" >/dev/null || die 'life-os-vcn already exists; refusing duplicate.'
K="$HOME/.ssh/life-os-ed25519"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if [[ ! -f "$K" ]]; then ssh-keygen -q -t ed25519 -f "$K" -N '' -C life-os; fi
chmod 600 "$K"; [[ -f "$K.pub" ]] || die 'SSH key missing.'
echo 'Creating isolated OCI network. Only SSH port 22 will be accessible.'
VCN="$(oci network vcn create --region "$REG" --compartment-id "$T" --display-name life-os-vcn --cidr-blocks '["10.42.0.0/16"]' --dns-label lifeos --wait-for-state AVAILABLE --query data.id --raw-output)"
[[ "$VCN" == ocid1.vcn.* ]] || die 'VCN failed.'
INFO="$(oci network vcn get --region "$REG" --vcn-id "$VCN")"
RT="$(jq -r '.data."default-route-table-id"' <<< "$INFO")"
SL="$(jq -r '.data."default-security-list-id"' <<< "$INFO")"
IG="$(oci network internet-gateway create --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --is-enabled true --display-name life-os-ig --wait-for-state AVAILABLE --query data.id --raw-output)"
oci network route-table update --region "$REG" --rt-id "$RT" --route-rules "$(jq -cn --arg ig "$IG" '[{cidrBlock:"0.0.0.0/0",networkEntityId:$ig}]')" --force >/dev/null
oci network security-list update --region "$REG" --security-list-id "$SL" --ingress-security-rules '[{"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}}]' --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]' --force >/dev/null
SUB="$(oci network subnet create --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --cidr-block 10.42.1.0/24 --display-name life-os-subnet --dns-label subnet --prohibit-public-ip-on-vnic false --wait-for-state AVAILABLE --query data.id --raw-output)"
[[ "$SUB" == ocid1.subnet.* ]] || die 'Subnet failed.'
ID=''
for AD in $(jq -r '.data[].name' "$D/ads.json"); do
 echo "Trying Always Free VM.Standard.A1.Flex 2 OCPU/12GB in $AD"
 if J="$(oci compute instance launch --region "$REG" --compartment-id "$T" --availability-domain "$AD" --display-name life-os --shape VM.Standard.A1.Flex --shape-config '{"ocpus":2,"memoryInGBs":12}' --image-id "$IMG" --boot-volume-size-in-gbs 50 --subnet-id "$SUB" --assign-public-ip true --ssh-authorized-keys-file "$K.pub" 2>"$D/launch.err")"; then
  ID="$(jq -r '.data.id//empty' <<< "$J")"; break
 fi
 if ! grep -Eiq 'out.?of.?host.?capacity|capacity' "$D/launch.err"; then cat "$D/launch.err" >&2; die 'Non-capacity launch error: no fallback.'; fi
done
[[ "$ID" == ocid1.instance.* ]] || die 'No A1 capacity. Paid VM not attempted. VCN may remain: do not rerun before inspecting it.'
echo "$ID" > "$D/instance-ocid"
oci compute instance get --region "$REG" --instance-id "$ID" --wait-for-state RUNNING > "$D/instance.json" || die 'VM created, RUNNING not confirmed.'
VN="$(oci compute vnic-attachment list --region "$REG" --compartment-id "$T" --instance-id "$ID" --query 'data[0]."vnic-id"' --raw-output)"
IP="$(oci network vnic get --region "$REG" --vnic-id "$VN" --query 'data."public-ip"' --raw-output)"
printf '\nCREATED RUNNING: %s\nIP: %s\nKey: %s\nTo connect: ssh -i %s ubuntu@%s\n' "$ID" "$IP" "$K" "$K" "$IP"
printf 'VPS is ready. ChatGPT browser bridge is NOT installed by this step.\n'
