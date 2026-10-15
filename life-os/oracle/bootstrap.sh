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
echo 'Creating isolated OCI network. Only SSH port 22 will be accessible.'
if [[ -z "$VCN" ]]; then
 VCN="$(oci network vcn create --region "$REG" --compartment-id "$T" --display-name life-os-vcn --cidr-blocks '["10.42.0.0/16"]' --dns-label lifeos --wait-for-state AVAILABLE --query data.id --raw-output)"
else
 echo 'Reusing previously created life-os VCN.'
 oci network vcn get --region "$REG" --vcn-id "$VCN" > "$D/vcn.json"
 jq -e '.data."cidr-blocks"|index("10.42.0.0/16")!=null' "$D/vcn.json" >/dev/null || die 'Existing VCN CIDR mismatch.'
fi
[[ "$VCN" == ocid1.vcn.* ]] || die 'VCN failed.'
INFO="$(oci network vcn get --region "$REG" --vcn-id "$VCN")"
RT="$(jq -r '.data."default-route-table-id"' <<< "$INFO")"
SL="$(jq -r '.data."default-security-list-id"' <<< "$INFO")"
oci network internet-gateway list --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --all > "$D/igs.json"
IG="$(jq -r '[.data[]|select(."display-name"=="life-os-ig" and ."lifecycle-state"=="AVAILABLE")]|.[0].id//empty' "$D/igs.json")"
if [[ -z "$IG" ]]; then
 IG="$(oci network internet-gateway create --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --is-enabled true --display-name life-os-ig --wait-for-state AVAILABLE --query data.id --raw-output)"
fi
oci network route-table update --region "$REG" --rt-id "$RT" --route-rules "$(jq -cn --arg ig "$IG" '[{cidrBlock:"0.0.0.0/0",networkEntityId:$ig}]')" --force >/dev/null
oci network security-list update --region "$REG" --security-list-id "$SL" --ingress-security-rules '[{"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}}]' --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]' --force >/dev/null
oci network subnet list --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --all > "$D/subnets.json"
SUB="$(jq -r '[.data[]|select(."display-name"=="life-os-subnet" and ."lifecycle-state"=="AVAILABLE")]|.[0].id//empty' "$D/subnets.json")"
if [[ -z "$SUB" ]]; then
 SUB="$(oci network subnet create --region "$REG" --compartment-id "$T" --vcn-id "$VCN" --cidr-block 10.42.1.0/24 --display-name life-os-subnet --dns-label subnet --prohibit-public-ip-on-vnic false --wait-for-state AVAILABLE --query data.id --raw-output)"
fi
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
