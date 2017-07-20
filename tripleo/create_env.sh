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

ssh_key_dir="/home/jenkins"

# base image for VMs
BASE_IMAGE_NAME=${BASE_IMAGE_NAME:-"undercloud-${ENVIRONMENT_OS}.qcow2"}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-'/home/root/images'}
mkdir -p ${BASE_IMAGE_DIR}
BASE_IMAGE="${BASE_IMAGE_DIR}/${BASE_IMAGE_NAME}"

# number of machines in overcloud
# by default scripts will create hyperconverged environment with SDS on compute
CONTROLLER_COUNT=${CONTROLLER_COUNT:-1}
COMPUTE_COUNT=${COMPUTE_COUNT:-2}
STORAGE_COUNT=${STORAGE_COUNT:-0}
CONTRAIL_CONTROLLER_COUNT=${CONTRAIL_CONTROLLER_COUNT:-1}
CONTRAIL_ANALYTICS_COUNT=${CONTRAIL_ANALYTICS_COUNT:-1}
CONTRAIL_ANALYTICSDB_COUNT=${CONTRAIL_ANALYTICSDB_COUNT:-1}

# Dir with contrail packages
CONTRAIL_PACKAGES_DIR=${CONTRAIL_PACKAGES_DIR:-'/home/root/contrail/latest'}

# ready image for undercloud - using CentOS cloud image. just run and ssh into it.
if [[ ! -f ${BASE_IMAGE} ]] ; then
  if [[ "$ENVIRONMENT_OS" == "centos" ]] ; then
    wget -O ${BASE_IMAGE} https://cloud.centos.org/centos/7/images/${BASE_IMAGE_NAME}
  else
    echo Download of image is implemented only for CentOS based environment
    exit 1
  fi
fi

# disk size for overcloud machines
vm_disk_size="30G"
# volume's poolname
poolname="rdimages"
net_driver=${net_driver:-e1000}

source "$my_dir/functions"

# check if environment is present
if virsh list --all | grep -q "rd-undercloud-$NUM" ; then
  echo 'ERROR: environment present. please clean up first'
  virsh list --all | grep "cloud-$NUM"
  exit 1
fi

# create three networks (i don't know why external is needed)
create_network management
mgmt_net=`get_network_name management`
create_network provisioning
prov_net=`get_network_name provisioning`
create_network external
ext_net=`get_network_name external`

# create pool
virsh pool-info $poolname &> /dev/null || create_pool $poolname
pool_path=$(get_pool_path $poolname)

function create_root_volume() {
  local name=$1
  delete_volume $name.qcow2 $poolname
  qemu-img create -f qcow2 -o preallocation=metadata $pool_path/$name.qcow2 $vm_disk_size
}

function create_store_volume() {
  local name=$1
  delete_volume $name-store.qcow2 $poolname
  qemu-img create -f qcow2 -o preallocation=metadata $pool_path/$name-store.qcow2 100G
}

function define-machine() {
  local name="$1"
  shift
  local disk_opt="$@"
  virt-install --name $name \
    --ram 8192 \
    --vcpus 2 \
    --os-variant rhel7 \
    $disk_opt \
    --noautoconsole \
    --vnc \
    --network network=$prov_net,model=$net_driver \
    --network network=$ext_net,model=$net_driver \
    --cpu SandyBridge,+vmx \
    --dry-run --print-xml > /tmp/oc-$name.xml
  virsh define --file /tmp/oc-$name.xml
}

function define_overcloud_vms() {
  local name=$1
  local count=$2
  local do_create_storage=${3:-'false'}
  local number_re='^[0-9]+$'
  if [[ $count =~ $number_re ]] ; then
    for (( i=1 ; i<=count; i++ )) ; do
      local vol_name="overcloud-$NUM-${name}-$i"
      create_root_volume $vol_name
      local disk_opts="--disk path=${pool_path}/${vol_name}.qcow2,device=disk,bus=virtio,format=qcow2"
      if [[ "$do_create_storage" == 'true' ]] ; then
        create_store_volume $vol_name
        disk_opts+=" --disk path=${pool_path}/${vol_name}-store.qcow2,device=disk,bus=virtio,format=qcow2"
      fi
      define-machine "rd-$vol_name" "$disk_opts"
    done
  else
    echo Skip VM $name creation, count=$count
  fi
}

# just define overcloud machines
define_overcloud_vms 'cont' $CONTROLLER_COUNT
define_overcloud_vms 'comp' $COMPUTE_COUNT 'true'
define_overcloud_vms 'stor' $STORAGE_COUNT 'true'
define_overcloud_vms 'ctrlcont' $CONTRAIL_CONTROLLER_COUNT
define_overcloud_vms 'ctrlanalytics' $CONTRAIL_ANALYTICS_COUNT
define_overcloud_vms 'ctrlanalyticsdb' $CONTRAIL_ANALYTICSDB_COUNT


# copy image for undercloud and resize them
cp $BASE_IMAGE $pool_path/undercloud-$NUM.qcow2

# for RHEL env enable repos appropriate to OpenStack version
# TODO: code duplication with __undercloud-install-2-as-stack-user.sh
if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  enable_repo=""
  if [[ "$OPENSTACK_VERSION" == 'newton' ]] ; then
    enable_repo="10"
  elif [[ "$OPENSTACK_VERSION" == 'ocata' ]] ; then
    enable_repo="11"
  else
    echo "ERROR: unsupported OS $OPENSTACK_VERSION for $ENVIRONMENT_OS environment"
    exit 1
  fi
  enable_repo_opts="--enable=rhel-7-server-openstack-${enable_repo}-rpms"
  enable_repo_opts+=" --enable=rhel-7-server-openstack-${enable_repo}-devtools-rpms"
  virt-customize -a $pool_path/undercloud-$NUM.qcow2 \
        --run-command "subscription-manager repos $enable_repo_opts"
fi


# define MAC's
mgmt_ip=$(get_network_ip "management")
mgmt_mac="00:16:00:00:0$NUM:02"
prov_ip=$(get_network_ip "provisioning")
prov_mac="00:16:00:00:0$NUM:06"
# generate password/key for undercloud's root
rm -f "$ssh_key_dir/kp-$NUM" "$ssh_key_dir/kp-$NUM.pub"
ssh-keygen -b 2048 -t rsa -f "$ssh_key_dir/kp-$NUM" -q -N ""
rootpass=`openssl passwd -1 123`

#check that nbd kernel module is loaded
if ! lsmod |grep '^nbd ' ; then
  modprobe nbd max_part=8
fi

# TODO: use guestfish instead of manual attachment
# mount undercloud root disk. (it helps to create multienv)
# !!! WARNING !!! in case of errors you need to unmount/disconnect it manually!!!
nbd_dev="/dev/nbd${NUM}"
qemu-nbd -d $nbd_dev || true
qemu-nbd -n -c $nbd_dev $pool_path/undercloud-$NUM.qcow2
sleep 5
ret=0
tmpdir=$(mktemp -d)
mount ${nbd_dev}p1 $tmpdir || ret=1
sleep 2

function change_undercloud_image() {
  # configure eth0 - management
  cp "$my_dir/ifcfg-ethM" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth0
  sed -i "s/{{network}}/$mgmt_ip/g" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth0
  sed -i "s/{{mac-address}}/$mgmt_mac/g" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth0
  sed -i "s/{{num}}/$NUM/g" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth0
  # configure eth1 - provisioning
  cp "$my_dir/ifcfg-ethA" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth1
  sed -i "s/{{network}}/$prov_ip/g" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth1
  sed -i "s/{{mac-address}}/$prov_mac/g" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth1
  # configure root access
  mkdir -p $tmpdir/root/.ssh
  cp "$ssh_key_dir/kp-$NUM.pub" $tmpdir/root/.ssh/authorized_keys
  cp "/home/stack/.ssh/id_rsa" $tmpdir/root/stack_id_rsa
  cp "/home/stack/.ssh/id_rsa.pub" $tmpdir/root/stack_id_rsa.pub
  echo "PS1='\${debian_chroot:+(\$debian_chroot)}undercloud:\[\033[01;31m\](\$?)\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\\\$ '" >> $tmpdir/root/.bashrc
  sed -i "s root:\*: root:$rootpass: " $tmpdir/etc/shadow
  sed -i "s root:\!\!: root:$rootpass: " $tmpdir/etc/shadow
  grep root $tmpdir/etc/shadow
  echo "PermitRootLogin yes" > $tmpdir/etc/ssh/sshd_config
  rm -rf $tmpdir/root/contrail_packages
  mkdir -p $tmpdir/root/contrail_packages
  cp $CONTRAIL_PACKAGES_DIR/* $tmpdir/root/contrail_packages/
}

# patch image
[ $ret == 0 ] && change_undercloud_image || ret=2

# unmount disk
[ $ret != 1 ] && umount ${nbd_dev}p1 || ret=2
sleep 2
rm -rf $tmpdir || ret=3
qemu-nbd -d $nbd_dev || ret=4
sleep 2

if [[ $ret != 0 ]] ; then
  echo "ERROR: there were errors in changing undercloud image, ret=$ret"
  exit 1
fi

# define and start undercloud machine
virt-install --name=rd-undercloud-$NUM \
  --ram=8192 \
  --vcpus=1,cores=1 \
  --os-type=linux \
  --os-variant=rhel7 \
  --virt-type=kvm \
  --disk "path=$pool_path/undercloud-$NUM.qcow2",size=40,cache=writeback,bus=virtio,serial=$(uuidgen) \
  --boot hd \
  --noautoconsole \
  --network network=$mgmt_net,model=$net_driver,mac=$mgmt_mac \
  --network network=$prov_net,model=$net_driver,mac=$prov_mac \
  --network network=$ext_net,model=$net_driver \
  --graphics vnc,listen=0.0.0.0


# wait for undercloud machine
iter=0
truncate -s 0 ./tmp_file
while ! scp -i "$ssh_key_dir/kp-$NUM" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -B ./tmp_file root@${mgmt_ip}.2:/tmp/tmp_file ; do
  if (( iter >= 20 )) ; then
    echo "Could not connect to undercloud"
    exit 1
  fi
  echo "Waiting for undercloud..."
  sleep 30
  ((++iter))
done
