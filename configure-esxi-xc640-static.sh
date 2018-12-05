#!/bin/sh

# Based on https://confluence.puppetlabs.com/display/SRE/Adding+new+host+to+ESXi+cluster

set -e

# bolt splits stdout and stderr, so combine them.
exec 2>&1

check_param () {
  local value="$1"
  local function_name="$2"
  local name="$3"
  if [ -z "$value" ] ; then
    echo "No ${name} passed to ${function_name}" >&2
    exit 1
  fi
}

is_other_output () {
  local string="$1"
  local output_file="$2"

  grep -q "$string" "$output_file" || return 1
  grep -v "$string" "$output_file" | grep -q .
}

error_check () {
  local allowed="$1"
  local command="$2"
  shift ; shift

  check_param "$allowed" error_check "allowed error"
  check_param "$command" error_check "command"

  local output=$(mktemp)

  # Can't use _esxcli because it outputs to $output
  echo "$command $@"
  set +e
  $command "$@" 2>&1 >"$output"
  local ret="$?"
  set -e

  ### FIXME if output is blank, this returns success

  if [ $ret == 0 ] ; then
    cat "$output"
    rm -f "$output"
  elif is_other_output "$allowed" "$output" ; then
    # There is output other than $allowed, or $allowed isn't present
    cat "$output"
    rm -f "$output"
    exit "$ret"
  else
    # Only $allowed was returned
    rm -f "$output"
  fi
}

# set -x is too noisy, so just print esxcli commands
_esxcli () {
  echo esxcli "$@"
  esxcli "$@"
}

add_vswitch () {
  local name=$1
  check_param "$name" add_vswitch "vSwitch name"

  error_check "A portset with this name already exists" \
    esxcli network vswitch standard add -v "$name"

  error_check '^Uplink already exists: vmnic0$' \
    esxcli network vswitch standard uplink add -v "$name" -u vmnic0
  error_check '^Uplink already exists: vmnic1$' \
    esxcli network vswitch standard uplink add -v "$name" -u vmnic1

  error_check '^No such uplink: vmnic2$' \
    esxcli network vswitch standard uplink remove -v "$name" -u vmnic2
  error_check '^No such uplink: vmnic3$' \
    esxcli network vswitch standard uplink remove -v "$name" -u vmnic3

  _esxcli network vswitch standard policy failover set -v "$name" -a vmnic0,vmnic1

  # This sets the maximum MTU accepted. The physical switch determines the MTU
  # of each VLAN.
  _esxcli network vswitch standard set --mtu=9000 -v "$name"
}

portgroup_add () {
  local vswitch="$1"
  local name="$2"
  local vlan="$3"

  check_param "$vswitch" portgroup_add "vSwitch name"
  check_param "$name" portgroup_add "portgroup name"
  check_param "$vlan" portgroup_add "VLAN id"

  error_check '^A portgroup with the name .* already exists$' \
    esxcli network vswitch standard portgroup add -p "$name" -v "$vswitch"
  _esxcli network vswitch standard portgroup set -p "$name" --vlan-id "$vlan"
}

network_interface_add () {
  local name="$1"
  local portgroup="$2"

  check_param "$name" network_interface_add "vmkernel nic name"
  check_param "$portgroup" network_interface_add "portgroup name"

  error_check "A vmkernel nic for the connection point already exists" \
    esxcli network ip interface add --interface-name "$name" --portgroup-name "$portgroup"
}

network_interface_tag () {
  local name="$1"
  shift

  check_param "$name" network_interface_tag "vmkernel nic name"

  for tag in "$@" ; do
    error_check "Vmknic is already tagged with ${tag}" \
      esxcli network ip interface tag add -i "$name" -t "$tag"
  done
}

ntp_backup=/tmp/ntp.conf-$(date +%Y-%m-%d_%H:%M:%S)
cp /etc/ntp.conf "$ntp_backup"
echo "Backed up ntp.conf to ${ntp_backup}. Updating."
grep -v '^server' "$ntp_backup" >/etc/ntp.conf
cat >> /etc/ntp.conf <<-EOF
server opdx-net01-prod.ops.puppetlabs.net
server pdx-net01-prod.ops.puppetlabs.net
server opdx-net02.service.puppetlabs.net
server pdx-net02-prod.ops.puppetlabs.net
EOF

/sbin/chkconfig ntpd on
/etc/init.d/ntpd restart

_esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1


# Enable 'L1 Terminal Fault' vulnerability mitigation
# https://rakhesh.com/virtualization/what-is-esx-problem-hyperthreading-unmitigated/
_esxcli system settings kernel set -s hyperthreadingMitigation -v TRUE

# Increase the number of allowed NFS data stores (defaults to 8 NFS data stores)
# https://kb.vmware.com/s/article/1020652, https://kb.vmware.com/s/article/2239

### Is there a downside to increasing this?
_esxcli system settings advanced set -o "/NFS/MaxVolumes" -i 256

_esxcli system syslog config set --loghost=udp://rsyslog.ops.puppetlabs.net:514
_esxcli system syslog reload
_esxcli network firewall ruleset set --ruleset-id=syslog --enabled=true
_esxcli network firewall refresh

# VMotion should only be tagged on vmk10
error_check "Error removing tag VMotion from interface .* Vmknic is not tagged with .*" \
  esxcli network ip interface tag remove -i vmk0 -t VMotion

add_vswitch vSwitch0
error_check "Sysinfo error: Not found" \
  esxcli network vswitch standard portgroup remove -p "VM Network" -v vSwitch0

# Private network
portgroup_add vSwitch0 private 97 # vmw
network_interface_add vmk10 private
_esxcli network ip interface ipv4 set -i vmk10 -t dhcp
_esxcli network ip interface ipv6 set -i vmk10 --enable-dhcpv6 1
network_interface_tag vmk10 faultToleranceLogging VMotion

# Storage network (needs MTU 9000 on vSwitch0 and vmk0)
portgroup_add vSwitch0 storage1 92
network_interface_add vmk11 storage1
_esxcli network ip interface set --mtu 9000 -i vmk11
_esxcli network ip interface ipv4 set -i vmk11 -t dhcp
_esxcli network ip interface ipv6 set -i vmk11 --enable-dhcpv6 1

# VM port groups. Leaving most out until we've determined we need them.
portgroup_add vSwitch0 delivery 77
portgroup_add vSwitch0 delivery_b 84
# portgroup_add vSwitch0 dmz_support 93
# portgroup_add vSwitch0 echonet-ops 86
# portgroup_add vSwitch0 eng 98
# portgroup_add vSwitch0 esxi 95
# portgroup_add vSwitch0 external 11
# portgroup_add vSwitch0 it2 2
# portgroup_add vSwitch0 ldap-dmz 302
# portgroup_add vSwitch0 netflow 200
# portgroup_add vSwitch0 oob 88
portgroup_add vSwitch0 ops 22
# portgroup_add vSwitch0 phones 33

# Set up storage
error_check "tintri-data-opdx-1-1.ops.puppetlabs.net:/tintri/general1 is already exported by a volume with the name tintri-opdx-1-general1" \
  esxcli storage nfs add -H tintri-data-opdx-1-1.ops.puppetlabs.net -s /tintri/general1 -v tintri-opdx-1-general1

_esxcli network ip set --ipv6-enabled false
