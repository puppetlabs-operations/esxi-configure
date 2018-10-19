#!/bin/sh

# Based on https://confluence.puppetlabs.com/display/SRE/Adding+new+host+to+ESXi+cluster

set -e -x

add_vswitch () {
  name=$1
  if [ -z "$name" ] ; then
    echo "No vSwitch name passed to add_vswitch" >&2
    exit 1
  fi

  esxcli network vswitch standard add -v "$name"
  esxcli network vswitch standard uplink add -v "$name" -u vmnic0
  esxcli network vswitch standard uplink add -v "$name" -u vmnic1
  esxcli network vswitch standard policy failover set -v "$name" -a vmnic0,vmnic1
}

#esxcli system hostname set -H <hostname>

ntp_backup=/tmp/ntp.conf-$(date +%Y-%m-%d_%H:%M:%S)
cp /etc/ntp.conf "$ntp_backup"
grep -v '^server' "$ntp_backup" >/etc/ntp.conf
cat >> /etc/ntp.conf <<-EOF
server opdx-net01-prod.ops.puppetlabs.net
server pdx-net01-prod.ops.puppetlabs.net
server opdx-net02.service.puppetlabs.net
server pdx-net02-prod.ops.puppetlabs.net
EOF

/sbin/chkconfig ntpd on
/etc/init.d/ntpd restart

esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1


# Enable 'L1 Terminal Fault' vulnerability mitigation
# https://rakhesh.com/virtualization/what-is-esx-problem-hyperthreading-unmitigated/
esxcli system settings kernel set -s hyperthreadingMitigation -v TRUE

# Increase the number of allowed NFS data stores (defaults to 8 NFS data stores)
# https://kb.vmware.com/s/article/1020652, https://kb.vmware.com/s/article/2239

### Is there a downside to increasing this?
esxcli system settings advanced set -o "/NFS/MaxVolumes" -i 256

esxcli system syslog config set --loghost=udp://rsyslog.ops.puppetlabs.net:514
esxcli system syslog reload
esxcli network firewall ruleset set --ruleset-id=syslog --enabled=true
esxcli network firewall refresh

# Set both adapters to active on management vSwitch, remove default VM network
esxcli network vswitch standard policy failover set -v vSwitch0 -a vmnic0,vmnic1
esxcli network vswitch standard portgroup remove -p "VM Network" -v vSwitch0

# vSwitch1: private network
add_vswitch vSwitch1
esxcli network vswitch standard portgroup add -p private -v vSwitch1
esxcli network ip interface add --interface-name vmk1 --portgroup-name private
esxcli network ip interface ipv4 set -i vmk1 -t dhcp
esxcli network ip interface ipv6 set -i vmk1 --enable-dhcpv6 1
esxcli network ip interface tag add -i vmk1 -t faultToleranceLogging
esxcli network ip interface tag add -i vmk1 -t VMotion

# vSwitch2: Storage network
add_vswitch vSwitch2
esxcli network vswitch standard set --mtu=9000 -v vSwitch2
esxcli network vswitch standard portgroup add -p storage1 -v vSwitch2
esxcli network vswitch standard portgroup set -p storage1 --vlan-id 92
esxcli network ip interface add --interface-name vmk2 --portgroup-name storage1
esxcli network ip interface set --mtu 9000 -i vmk2
esxcli network ip interface ipv4 set -i vmk2 -t dhcp
esxcli network ip interface ipv6 set -i vmk2 --enable-dhcpv6 1
### Do we need storage2 (96)?
# esxcli network vswitch standard portgroup add -p storage2 -v vSwitch2
# esxcli network vswitch standard portgroup set -p storage2 --vlan-id 96
# esxcli network ip interface add --interface-name vmk3 --portgroup-name storage2
# esxcli network ip interface set --mtu 9000 -i vmk3
# esxcli network ip interface ipv4 set -i vmk3 -t dhcp
# esxcli network ip interface ipv6 set -i vmk3 --enable-dhcpv6 1

# vSwitch3: VM port groups
add_vswitch vSwitch3
esxcli network vswitch standard portgroup add -p delivery -v vSwitch3
esxcli network vswitch standard portgroup set -p delivery --vlan-id 77
esxcli network vswitch standard portgroup add -p delivery_b -v vSwitch3
esxcli network vswitch standard portgroup set -p delivery_b --vlan-id 84
# esxcli network vswitch standard portgroup add -p dmz_support -v vSwitch3
# esxcli network vswitch standard portgroup set -p dmz_support --vlan-id 93
# esxcli network vswitch standard portgroup add -p echonet-ops -v vSwitch3
# esxcli network vswitch standard portgroup set -p echonet-ops --vlan-id 86
# esxcli network vswitch standard portgroup add -p eng -v vSwitch3
# esxcli network vswitch standard portgroup set -p eng --vlan-id 98
# esxcli network vswitch standard portgroup add -p esxi -v vSwitch3
# esxcli network vswitch standard portgroup set -p esxi --vlan-id 95
# esxcli network vswitch standard portgroup add -p external -v vSwitch3
# esxcli network vswitch standard portgroup set -p external --vlan-id 11
# esxcli network vswitch standard portgroup add -p it2 -v vSwitch3
# esxcli network vswitch standard portgroup set -p it2 --vlan-id 2
# esxcli network vswitch standard portgroup add -p ldap-dmz -v vSwitch3
# esxcli network vswitch standard portgroup set -p ldap-dmz --vlan-id 302
# esxcli network vswitch standard portgroup add -p netflow -v vSwitch3
# esxcli network vswitch standard portgroup set -p netflow --vlan-id 200
# esxcli network vswitch standard portgroup add -p oob -v vSwitch3
# esxcli network vswitch standard portgroup set -p oob --vlan-id 88
esxcli network vswitch standard portgroup add -p ops -v vSwitch3
esxcli network vswitch standard portgroup set -p ops --vlan-id 22
# esxcli network vswitch standard portgroup add -p phones -v vSwitch3
# esxcli network vswitch standard portgroup set -p phones --vlan-id 33

# Set up storage
esxcli storage nfs add -H tintri-data-opdx-1-1.ops.puppetlabs.net -s /tintri/general1 -v tintri-opdx-1-general1

esxcli network ip set --ipv6-enabled false

reboot
