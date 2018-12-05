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
  shift
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
error_check "Invalid Key Name: hyperthreadingMitigation" \
  esxcli system settings kernel set -s hyperthreadingMitigation -v TRUE

# Increase the number of allowed NFS data stores (defaults to 8 NFS data stores)
# https://kb.vmware.com/s/article/1020652, https://kb.vmware.com/s/article/2239
_esxcli system settings advanced set -o "/NFS/MaxVolumes" -i 256

_esxcli system syslog config set --loghost=udp://rsyslog.ops.puppetlabs.net:514
_esxcli system syslog reload
_esxcli network firewall ruleset set --ruleset-id=syslog --enabled=true
_esxcli network firewall refresh

vswitch_add () {
  error_check "A portset with this name already exists" \
    esxcli network vswitch standard add -v "$1"
}

vswitch_uplink_add () {
  error_check '^Uplink already exists: ' \
    esxcli network vswitch standard uplink add -v "$1" -u "$2"
}

vswitch_add vSwitch0
vswitch_uplink_add vSwitch0 vmnic0
vswitch_uplink_add vSwitch0 vmnic1
_esxcli network vswitch standard policy failover set -v vSwitch0 -a vmnic0,vmnic1
error_check "Sysinfo error: Not found" \
  esxcli network vswitch standard portgroup remove -p "VM Network" -v vSwitch0

vswitch_add vSwitch1
vswitch_uplink_add vSwitch1 vmnic2
_esxcli network vswitch standard policy failover set -v vSwitch1 -a vmnic2
error_check '^A portgroup with the name .* already exists$' \
  esxcli network vswitch standard portgroup add -p private -v vSwitch1
_esxcli network ip interface add --interface-name vmk1 --portgroup-name private
_esxcli network ip interface ipv4 set -i vmk1 -t dhcp
_esxcli network ip interface ipv6 set -i vmk1 --enable-dhcpv6 1
network_interface_tag vmk1 faultToleranceLogging VMotion


vswitch_add vSwitch2
vswitch_uplink_add vSwitch2 vmnic3
_esxcli network vswitch standard policy failover set -v vSwitch2 -a vmnic3
_esxcli network vswitch standard set --mtu=9000 -v vSwitch2
portgroup_add vSwitch2 storage1 92
_esxcli network ip interface add --interface-name vmk2 --portgroup-name storage1
_esxcli network ip interface set --mtu 9000 -i vmk2
_esxcli network ip interface ipv4 set -i vmk2 -t dhcp
_esxcli network ip interface ipv6 set -i vmk2 --enable-dhcpv6 1
portgroup_add vSwitch2 storage2 96
esxcli network ip interface add --interface-name vmk3 --portgroup-name storage2
esxcli network ip interface set --mtu 9000 -i vmk3
esxcli network ip interface ipv4 set -i vmk3 -t dhcp
esxcli network ip interface ipv6 set -i vmk3 --enable-dhcpv6 1

vswitch_add vSwitch3
vswitch_uplink_add vSwitch3 vmnic4
vswitch_uplink_add vSwitch3 vmnic5
_esxcli network vswitch standard policy failover set -v vSwitch3 -a vmnic4,vmnic5

portgroup_add vSwitch3 razortest5 144
portgroup_add vSwitch3 razortest4 143
portgroup_add vSwitch3 razortest3 142
portgroup_add vSwitch3 razortest2 141
portgroup_add vSwitch3 razortest1 140
portgroup_add vSwitch3 delivery 77
portgroup_add vSwitch3 vmpooler 112

error_check " is already exported by a volume with the name " \
  esxcli storage nfs add -H stor-filer3-9k-1.ops.puppetlabs.net -s /tank02/instance1 -v instance1
error_check " is already exported by a volume with the name " \
  esxcli storage nfs add -H stor-filer6-9k-1.ops.puppetlabs.net -s /tank05/instance2 -v instance2_1
error_check " is already exported by a volume with the name " \
  esxcli storage nfs add -H stor-filer6-9k-1.ops.puppetlabs.net -s /tank05/instance3 -v instance3_1
error_check " is already exported by a volume with the name " \
  esxcli storage nfs add -H stor-filer6-9k-2.ops.puppetlabs.net -s /tank05/instance3 -v instance3_2

_esxcli network ip set --ipv6-enabled false
