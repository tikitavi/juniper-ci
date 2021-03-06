#!/bin/bash -ex

main_net_prefix=$1
prepare_for_openstack=$2

function do_trusty() {
  IF1=eth0
  if [[ "$prepare_for_openstack" == '1' ]]; then
    add-apt-repository -y cloud-archive:mitaka &>>apt.log
    apt-get update &>>apt.log
  fi
  cat >/etc/network/interfaces.d/50-cloud-init.cfg <<EOF
# The primary network interface
auto eth0
iface eth0 inet manual

auto br-eth0
iface br-eth0 inet dhcp
    bridge_ports eth0
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0

auto eth1
iface eth1 inet dhcp
EOF
  # '50-cloud-init.cfg' is default name for xenial and it is overwritten
  rm /etc/network/interfaces.d/eth0.cfg
}

function do_xenial() {
  IF1=ens3
  cat >/etc/network/interfaces.d/50-cloud-init.cfg <<EOF
# This file is generated from information provided by
# the datasource.  Changes to it will not persist across an instance.
# To disable cloud-init's network configuration capabilities, write a file
# /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg with the following:
# network: {config: disabled}
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet manual

auto br-ens3
iface br-ens3 inet dhcp
    bridge_ports ens3
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0

auto ens4
iface ens4 inet dhcp
EOF
}

function do_bionic() {
  IF1=ens3
  rm /etc/resolv.conf
  ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
  apt-get install ifupdown &>>apt.log
  echo "source /etc/network/interfaces.d/*" >> /etc/network/interfaces
  do_xenial
  mv /etc/netplan/50-cloud-init.yaml /etc/netplan/__50-cloud-init.yaml.save
}

DEBIAN_FRONTEND=noninteractive apt-get -fy install bridge-utils lxd &>>apt.log

echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

series=`lsb_release -cs`
do_$series
if [[ "$prepare_for_openstack" == '1' ]]; then
  if [ -f /etc/default/lxd-bridge ]; then
    sed -i -e "s/^USE_LXD_BRIDGE.*$/USE_LXD_BRIDGE=\"false\"/m" /etc/default/lxd-bridge
    sed -i -e "s/^LXD_BRIDGE.*$/LXD_BRIDGE=\"br-$IF1\"/m" /etc/default/lxd-bridge
  else
    echo "USE_LXD_BRIDGE=\"false\"" > /etc/default/lxd-bridge
    echo "LXD_BRIDGE=\"br-$IF1\"/m" >> /etc/default/lxd-bridge
  fi
fi

echo "supersede routers $main_net_prefix.1;" >> /etc/dhcp/dhclient.conf
