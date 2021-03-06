#!/bin/bash -ex

# this script file should be copied to undercloud machine and run there.

cd ~

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/functions"

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

CLOUD_DOMAIN_NAME=${CLOUD_DOMAIN_NAME:-'localdomain'}
NETDEV=${NETDEV:-'eth1'}

((addr=176+NUM*10))
prov_ip="192.168.$addr"
((addr=172+NUM*10))
mgmt_ip="192.168.$addr"
if [[ "$FREE_IPA" == 'true' ]] ; then
  dns_nameserver="${prov_ip}.4"
else
  dns_nameserver="8.8.8.8"
fi

# create undercloud configuration file. all IP addresses are relevant to create_env.sh script
if [[ -f /usr/share/instack-undercloud/undercloud.conf.sample ]] ; then
  cp /usr/share/instack-undercloud/undercloud.conf.sample ~/undercloud.conf
fi
cat << EOF >> undercloud.conf
[DEFAULT]
local_ip = $prov_ip.2/24
undercloud_public_host = $prov_ip.10
undercloud_admin_host = $prov_ip.11
local_interface = $NETDEV
overcloud_domain_name = $CLOUD_DOMAIN_NAME
undercloud_nameservers = $dns_nameserver
undercloud_hostname = undercloud.my${NUM}domain.local
discovery_iprange = $prov_ip.150,$prov_ip.170
subnets = ctlplane-subnet
inspection_interface = br-ctlplane
EOF

if [[ "$FREE_IPA" == 'true' ]] ; then
  cat << EOF >> undercloud.conf
enable_novajoin = True
ipa_otp = "$FREE_IPA_OTP"
EOF
fi

if [[ 'newton|ocata' =~ $OPENSTACK_VERSION ]]; then
  cat << EOF >> undercloud.conf
network_cidr = $prov_ip.0/24
dhcp_start = $prov_ip.100
dhcp_end = $prov_ip.149
network_gateway = $prov_ip.2
inspection_iprange = $prov_ip.150,$prov_ip.170
masquerade_network = $prov_ip.0/24
masquerade = true
EOF
else
  cat << EOF >> undercloud.conf
[ctlplane-subnet]
cidr = $prov_ip.0/24
dhcp_start = $prov_ip.100
dhcp_end = $prov_ip.149
gateway = $prov_ip.2
inspection_iprange = $prov_ip.150,$prov_ip.170
masquerade = true
EOF
fi

if [[ "${ENVIRONMENT_OS_VERSION:0:1}" == '8' ]] ; then
  #openstack tripleo container image prepare default --local-push-destination --output-env-file containers-prepare-parameter.yaml
  cat << EOF > /tmp/containers-prepare-parameter.yaml
parameter_defaults:
  ContainerImagePrepare:
  - push_destination: true
    set:
      name_prefix: openstack-
      name_suffix: ''
      namespace: registry.redhat.io/rhosp-beta
      neutron_driver: ovn
      tag: 16.0
    tag_from_label: '{version}-{release}'
  ContainerImageRegistryCredentials:
    registry.redhat.io:
      \${RHEL_USER}: '\${RHEL_PASSWORD}'
EOF
  source rhel-account
  cat /tmp/containers-prepare-parameter.yaml | envsubst > containers-prepare-parameter.yaml
  sed -i '/\[DEFAULT\]/ a container_images_file = containers-prepare-parameter.yaml' undercloud.conf
fi  


# install undercloud
openstack undercloud install

# function to build images if needed
function create_images() {
  # next line is needed only if undercloud's OS is deifferent
  #export NODE_DIST=centos7
  export STABLE_RELEASE="$OPENSTACK_VERSION"
  # export USE_DELOREAN_TRUNK=1
  # export DELOREAN_REPO_FILE="delorean.repo"
  # export DELOREAN_TRUNK_REPO="http://trunk.rdoproject.org/centos7-$OPENSTACK_VERSION/current/"
  export DIB_YUM_REPO_CONF=/etc/yum.repos.d/delorean*

  # package redhat-lsb-core is absent due to some bug in newton image
  # workaround is to add ceph repo:
  # there is enabled jewel repo in centos image
  # export DIB_YUM_REPO_CONF="$DIB_YUM_REPO_CONF /etc/yum.repos.d/CentOS-Ceph-Hammer.repo"

  #export DELOREAN_TRUNK_REPO="http://buildlogs.centos.org/centos/7/cloud/x86_64/rdo-trunk-master-tripleo/"
  #export DIB_INSTALLTYPE_puppet_modules=source

  local config_opts=''
  if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
    if [[ "$OPENSTACK_VERSION" == 'train' ]] ; then
      export OS_YAML="/usr/share/openstack-tripleo-common/image-yaml/overcloud-images-rhel8.yaml"
      export REG_REPOS='rhel-7-for-x86_64-baseos-rpms rhel-8-for-x86_64-appstream-rpms rhel-8-for-x86_64-highavailability-rpms ansible-2.8-for-rhel-8-x86_64-rpms openstack-beta-for-rhel-8-x86_64-rpms satellite-tools-6.5-for-rhel-8-x86_64-rpms'
    else 	    
      export OS_YAML="/usr/share/openstack-tripleo-common/image-yaml/overcloud-images-rhel7.yaml"
      export REG_REPOS='rhel-7-server-rpms rhel-7-server-extras-rpms rhel-ha-for-rhel-7-server-rpms rhel-7-server-optional-rpms'
      if [ -f /home/stack/overcloud-base-image.qcow2 ] ; then
        export DIB_LOCAL_IMAGE='/home/stack/overcloud-base-image.qcow2'
      fi
      local rhel_account_file_name=$(echo $RHEL_ACCOUNT_FILE | awk -F '/' '{print($NF)}')
      set +x
      source ~/$rhel_account_file_name
      set -x
      config_opts="--config-file /usr/share/openstack-tripleo-common/image-yaml/overcloud-images.yaml --config-file $OS_YAML"
    fi  
  fi
  openstack overcloud image build $config_opts
}

function install_images() {
  local os_num="$(rhel_os2num).0"
  local packages_install_dir='/usr/share/rhosp-director-images'
  local ret=0
  tar -xvf $packages_install_dir/overcloud-full-latest-${os_num}.tar || ret=1
  tar -xvf $packages_install_dir/ironic-python-agent-latest-${os_num}.tar || ret=1
  return $ret
}


if [[ "${ENVIRONMENT_OS_VERSION:0:1}" == '8' ]] ; then
  source ~/stackrc
  sudo yum -y install rhosp-director-images rhosp-director-images-ipa
  mkdir ~/images
  cd ~/images
  for i in /usr/share/rhosp-director-images/overcloud-full-latest-15.0.tar \
           /usr/share/rhosp-director-images/ironic-python-agent-latest-15.0.tar; 
    do
      tar -xvf $i; 
    done
  openstack overcloud image upload --image-path /home/stack/images/
  openstack image list
else 
  cd ~
  if [ -f /tmp/images.tar ] ; then
    # but right now script will use previously built images
    tar -xf /tmp/images.tar
  else
    mkdir -p images
    pushd images

    if ! install_images ; then
      create_images
    fi
    if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
      rhel_customize "overcloud-full.qcow2" 'overcloud'
    fi
    popd
    tar -cf images.tar images
  fi

  source ./stackrc
  cd ~/images
  openstack overcloud image upload
  cd ..
fi

# update undercloud's network information
sid=`neutron subnet-list | grep " $prov_ip.0" | awk '{print $2}'`
neutron subnet-update $sid --dns-nameserver $dns_nameserver
