#!/bin/bash -ex

# suffix for deployment
if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment number. (export NUM=4)"
  exit 1
fi

if [[ -z "$OPENSTACK_VERSION" ]] ; then
  echo "OPENSTACK_VERSION is expected (e.g. export OPENSTACK_VERSION=newton)"
  exit 1
fi

if [[ -z "$ENVIRONMENT_OS" ]] ; then
  echo "ENVIRONMENT_OS is expected (e.g. export ENVIRONMENT_OS=centos)"
  exit 1
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# base image for VMs
DEFAULT_BASE_IMAGE_NAME="undercloud-${ENVIRONMENT_OS}-${ENVIRONMENT_OS_VERSION}.qcow2"
BASE_IMAGE_NAME=${BASE_IMAGE_NAME:-"$DEFAULT_BASE_IMAGE_NAME"}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-'/home/root/images'}
mkdir -p ${BASE_IMAGE_DIR}
BASE_IMAGE="${BASE_IMAGE_DIR}/${BASE_IMAGE_NAME}"
BASE_IMAGE_POOL=${BASE_IMAGE_POOL:-'images'}

BRIDGE_NAME_MGMT=${BRIDGE_NAME_MGMT:-"rd-mgmt-${NUM}"}
BRIDGE_NAME_PROV=${BRIDGE_NAME_PROV:-"rd-prov-${NUM}"}
NET_NAME_MGMT=${NET_NAME_MGMT:-${BRIDGE_NAME_MGMT}}
NET_NAME_PROV=${NET_NAME_PROV:-${BRIDGE_NAME_PROV}}
(( netnum=100+$NUM*10 ))
NET_ADDR_MGMT=${NET_ADDR_MGMT:-"192.168.${netnum}.0"}
(( netnum+=5 ))
NET_ADDR_PROV=${NET_ADDR_PROV:-"192.168.${netnum}.0"}
PROV_NETDEV=${PROV_NETDEV:-'ens4'}

# number of machines in overcloud
# by default scripts will create hyperconverged environment with SDS on compute
CONTROLLER_COUNT=${CONTROLLER_COUNT:-1}
COMPUTE_COUNT=${COMPUTE_COUNT:-2}
STORAGE_COUNT=${STORAGE_COUNT:-1}
NETNODE_COUNT=${NETNODE_COUNT:-3}

# disk size for overcloud machines
vm_disk_size="30G"
# volume's poolname
poolname="rdimages"
net_driver=${net_driver:-e1000}

source "$my_dir/../common/virsh/functions"

# check if environment is present
assert_env_exists "rd-undercloud-$NUM"

create_network_dhcp $NET_NAME_MGMT $NET_ADDR_MGMT $BRIDGE_NAME_MGMT
prov_dhcp='yes'
create_network_dhcp $NET_NAME_PROV $NET_ADDR_PROV $BRIDGE_NAME_PROV $prov_dhcp

# create pool
create_pool $poolname

function define_overcloud_vms() {
  local name=$1
  local count=$2
  local mem=$3
  local disk_size=${4:-40}
  local number_re='^[0-9]+$'
  if [[ $count =~ $number_re ]] ; then
    for (( i=1 ; i<=count; i++ )) ; do
      local vm_name="rd-overcloud-${NUM}-${name}-${i}"
      local vol_name="${vm_name}.qcow2"
      local vol_path=$(create_new_volume $vol_name $poolname $disk_size)
      define_machine $vm_name 2 $mem rhel7 $NET_NAME_PROV "$vol_path"
    done
  else
    echo Skip VM $name creation, count=$count
  fi
}

function define_and_start_full_vm() {
  local name=$1
  local count=$2
  local mem=$3
  local mac_mgmt_base=${4:-''}
  local ip_mgmt_base=${5:-''}
  local mac_prov=${6:-''}
  local ip_prov_base=${7:-''}
  local number_re='^[0-9]+$'
  if [[ $count =~ $number_re ]] ; then
    for (( i=1 ; i<=count; i++ )) ; do
      local vm_name="${name}${i}"
      local vol_name="${vm_name}.qcow2"
      local vol_path=$(create_volume_from "${vol_name}" $poolname $BASE_IMAGE_NAME $BASE_IMAGE_POOL)
      local net_opts=$NET_NAME_MGMT
      local mac_mgmt=''
      local mac_prov=''
      if [[ -n "$mac_mgmt_base" ]] ; then
        mac_mgmt="${mac_mgmt_base}:0${i}"
      fi
      if [[ -n "$mac_prov_base" ]] ; then
        mac_prov="${mac_prov_base}:0${i}"
      fi

      if [[ -n "$mac_mgmt" ]] ; then
        net_opts+="/${mac_mgmt}"
      fi
      net_opts+=",$NET_NAME_PROV"
      if [[ -n "$mac_prov" ]] ; then
        net_opts+="/${mac_prov}"
      fi
      define_machine $vm_name 2 $mem rhel7 "$net_opts" "$vol_path"
      if [[ -n "$mac_mgmt" && -n "$ip_mgmt_base" ]] ; then
        local _base="$(echo $ip_mgmt_base | cut -d '.' -f 1,2,3)"
        local _sfx="$(echo $ip_mgmt_base | cut -d '.' -f 4)"
        (( _sfx+=i ))
        local ip_mgmt="${_base}.${_sfx}"
        update_network_dhcp $NET_NAME_MGMT $vm_name $mac_mgmt $ip_mgmt
      fi
      if [[ -n "$mac_prov" && -n "$ip_prov_base" ]] ; then
        local _base="$(echo $ip_prov_base | cut -d '.' -f 1,2,3)"
        local _sfx="$(echo $ip_prov_base | cut -d '.' -f 4)"
        (( _sfx+=i ))
        local ip_prov="${_base}.${_sfx}"
        update_network_dhcp $NET_NAME_PROV $vm_name $mac_prov $ip_prov
      fi
      # customize domain to set root password
      # TODO: access denied under non root...
      # customized manually for now
      # domain_customize $name $name.local
      start_vm $vm_name
    done
  else
    echo Skip VM $name creation, count=$count
  fi
}

if [[ "$DEPLOY_STAGES" != 'clean_vms' ]] ; then

  # just define overcloud machines
  define_overcloud_vms 'cont' $CONTROLLER_COUNT 8192
  define_overcloud_vms 'comp' $COMPUTE_COUNT 4096
  define_overcloud_vms 'stor' $STORAGE_COUNT 2048
  define_overcloud_vms 'net' $NETNODE_COUNT 2024

  # make undercloud image from base image and define undercloud VM
  undercloud_vm_name="rd-undercloud-$NUM"
  undercloud_vol_path=$(create_volume_from "${undercloud_vm_name}.qcow2" $poolname $BASE_IMAGE_NAME $BASE_IMAGE_POOL)

  define_machine $undercloud_vm_name 2 8192 rhel7 "$NET_NAME_MGMT,$NET_NAME_PROV" "$undercloud_vol_path"
  # customize domain to set root password
  # TODO: access denied under non root...
  # customized manually for now
  # domain_customize undercloud_vm_name undercloud.local
  start_vm $undercloud_vm_name

  mgmt_ip=$(wait_dhcp $NET_NAME_MGMT 1 )
  wait_ssh $mgmt_ip

  prov_ip="$(echo $NET_ADDR_PROV | cut -d '.' -f 1,2,3).2"

  #ssh keys to acces hypervisor under stack user
  scp $SSH_OPTS ~/stack_user_rsa/* stack@${mgmt_ip}:~/.ssh/
  #host name and default ip route
  undercloud_hname="undercloud-$(echo $mgmt_ip | tr '.' '-')"
  default_route="$(echo $mgmt_ip | cut -d '.' -f 1,2,3).1"
  cat <<EOF | ssh $SSH_OPTS root@${mgmt_ip}
set -x
echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf
sysctl -p /etc/sysctl.conf
echo $undercloud_hname > /etc/hostname
hostname $undercloud_hname
domainname localdomain
echo $mgmt_ip ${undercloud_hname}.localdomain  ${undercloud_hname} >> /etc/hosts
ifdown $NETDEV_PROV || true
cat <<EOM > /etc/sysconfig/network-scripts/ifcfg-ens4
DEVICE=$NETDEV_PROV
BOOTPROTO=none
ONBOOT=yes
HOTPLUG=no
NM_CONTROLLED=no
DEVICETYPE=ovs
EOM
ifup $NETDEV_PROV || true
ip route del default || true
ip route add default via $default_route
echo nameserver $default_route >> /etc/resolv.conf
EOF

  export MGMT_IP=$mgmt_ip
  export PROV_IP=$prov_ip
  export PROV_NETDEV=${PROV_NETDEV:-$(ssh $SSH_OPTS root@${mgmt_ip} ip addr | grep $prov_ip | awk '{print($8)}')}
else


  net_mgmt_base_ip=$(echo "$NET_ADDR_MGMT" | cut -d '.' -f 1,2,3)
  net_prov_base_ip=$(echo "$NET_ADDR_PROV" | cut -d '.' -f 1,2,3)
  define_and_start_full_vm 'controller' $CONTROLLER_COUNT 4096 "52:54:00:0$NUM:01" "${net_mgmt_base_ip}.100" "52:54:00:0$NUM:02" "${net_prov_base_ip}.100"
  define_and_start_full_vm 'compute' $COMPUTE_COUNT 4096 "52:54:00:0$NUM:02" "${net_mgmt_base_ip}.110" "52:54:00:0$NUM:02" "${net_prov_base_ip}.100"
  define_and_start_full_vm 'network' $NETNODE_COUNT 4096 "52:54:00:0$NUM:03" "${net_mgmt_base_ip}.120" "52:54:00:0$NUM:02" "${net_prov_base_ip}.100"
  #define_full_vm 'stor' $STORAGE_COUNT 2048 "00:16:00:0$NUM:04"

fi
