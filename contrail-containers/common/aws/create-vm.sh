#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30"
ENV_FILE="$WORKSPACE/cloudrc"
VPC_CIDR="192.168.0.0/16"
VM_CIDR="192.168.130.0/24"
VM_CIDR_EXT="192.168.131.0/24"

trap 'catch_errors_cvm $LINENO' ERR EXIT
function catch_errors_cvm() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

source "$my_dir/${ENVIRONMENT_OS}"

echo "INFO: Image ID: $IMAGE_ID"

function get_value_from_json() {
  local cmd_out=$($1 | jq $2)
  eval "echo $cmd_out"
}


if [ -f $ENV_FILE ]; then
  echo "ERROR: Previous environment found. Please check and cleanup."
  exit 1
fi

touch $ENV_FILE
echo "AWS_FLAGS='${AWS_FLAGS}'" >> $ENV_FILE
echo "SSH_USER='${SSH_USER}'" >> $ENV_FILE
echo "INFO: -------------------------------------------------------------------------- $(date)"

cmd="aws ${AWS_FLAGS} ec2 create-vpc --cidr-block $VPC_CIDR"
vpc_id=$(get_value_from_json "$cmd" ".Vpc.VpcId")
echo "INFO: VPC_ID: $vpc_id"
echo "vpc_id=$vpc_id" >> $ENV_FILE
aws ${AWS_FLAGS} ec2 wait vpc-available --vpc-id $vpc_id

aws ${AWS_FLAGS} ec2 modify-vpc-attribute --vpc-id $vpc_id --enable-dns-hostnames
aws ${AWS_FLAGS} ec2 modify-vpc-attribute --vpc-id $vpc_id --enable-dns-support

cmd="aws ${AWS_FLAGS} ec2 create-subnet --vpc-id $vpc_id --cidr-block $VM_CIDR"
subnet_id=$(get_value_from_json "$cmd" ".Subnet.SubnetId")
echo "INFO: SUBNET_ID: $subnet_id"
echo "subnet_id=$subnet_id" >> $ENV_FILE
az=$(aws ${AWS_FLAGS} ec2 describe-subnets --subnet-id $subnet_id --query 'Subnets[*].AvailabilityZone' --output text)
echo "INFO: Availability zone for current deployment: $az"
echo "az=$az" >> $ENV_FILE
sleep 2
cmd="aws ${AWS_FLAGS} ec2 create-subnet --vpc-id $vpc_id --cidr-block $VM_CIDR_EXT --availability-zone $az"
subnet_ext_id=$(get_value_from_json "$cmd" ".Subnet.SubnetId")
echo "INFO: SUBNET_EXT_ID: $subnet_ext_id"
echo "subnet_ext_id=$subnet_ext_id" >> $ENV_FILE
sleep 2

cmd="aws ${AWS_FLAGS} ec2 create-internet-gateway"
igw_id=$(get_value_from_json "$cmd" ".InternetGateway.InternetGatewayId")
echo "INFO: IGW_ID: $igw_id"
echo "igw_id=$igw_id" >> $ENV_FILE

aws ${AWS_FLAGS} ec2 attach-internet-gateway --internet-gateway-id $igw_id --vpc-id $vpc_id

cmd="aws ${AWS_FLAGS} ec2 describe-route-tables --filters Name=vpc-id,Values=$vpc_id"
rtb_id=$(get_value_from_json "$cmd" ".RouteTables[0].RouteTableId")
echo "INFO: RTB_ID: $rtb_id"

aws ${AWS_FLAGS} ec2 create-route --route-table-id $rtb_id --destination-cidr-block "0.0.0.0/0" --gateway-id $igw_id

# here should be only one 'default' group
group_id=$(aws ${AWS_FLAGS} ec2 describe-security-groups --filters Name=vpc-id,Values=$vpc_id --query 'SecurityGroups[*].GroupId' --output text)
echo "INFO: Group ID: $group_id"
# ssh port
aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port 22
# docker port
aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port 5000
# contrail ports
aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port 8080
aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port 8143
aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port 80
aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port 6080
# openstack ports
#for port in 8774 8776 8788 5000 9696 8080 9292 35357 ; do
#  aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port $port
#done

key_name="testkey-$(cat /dev/urandom | tr -cd 'a-f0-9' | head -c 8)"
echo "key_name=$key_name" >> $ENV_FILE
key_result=$(aws ${AWS_FLAGS} ec2 create-key-pair --key-name $key_name)

kp=$(get_value_from_json "echo $key_result" ".KeyMaterial")
echo $kp | sed 's/\\n/\'$'\n''/g' > "$WORKSPACE/kp"
chmod 600 kp

function run_instance() {
  local type=$1
  local env_var_suffix=$2
  local cloud_vm=$3

  if [[ $cloud_vm == "true" ]]; then
    # it means that additional disks must be created for VM
    local bdm='{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":60,"DeleteOnTermination":true}},{"DeviceName":"/dev/xvdf","Ebs":{"VolumeSize":60,"DeleteOnTermination":true}}'
  else
    local bdm='{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":60,"DeleteOnTermination":true}}'
  fi
  local cmd=$(aws ${AWS_FLAGS} ec2 run-instances --image-id $IMAGE_ID --key-name $key_name --instance-type $type --subnet-id $subnet_id --associate-public-ip-address --block-device-mappings "[${bdm}]")
  local instance_id=$(get_value_from_json "echo $cmd" ".Instances[0].InstanceId")
  echo "INFO: $env_var_suffix INSTANCE_ID: $instance_id"
  echo "instance_id_${env_var_suffix}=$instance_id" >> $ENV_FILE

  time aws ${AWS_FLAGS} ec2 wait instance-running --instance-ids $instance_id
  echo "INFO: $env_var_suffix instance ready."

  local cmd_result=$(aws ${AWS_FLAGS} ec2 describe-instances --instance-ids $instance_id)
  local public_ip=$(get_value_from_json "echo $cmd_result" ".Reservations[0].Instances[0].PublicIpAddress")
  echo "INFO: $env_var_suffix public IP: $public_ip"
  echo "public_ip_${env_var_suffix}=$public_ip" >> $ENV_FILE

  # inner communication...
  aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr $public_ip/32 --protocol tcp --port 0-65535

  local ssh="ssh -i $WORKSPACE/kp $SSH_OPTS $SSH_USER@$public_ip"
  echo "INFO: waiting for instance SSH"
  while ! $ssh uname -a 2>/dev/null ; do
    echo "WARNING: Machine isn't accessible yet"
    sleep 2
  done
  if [[ $cloud_vm == "true" ]]; then
    echo "INFO: Configure additional disk for cloud VM"
    $ssh "(echo o; echo n; echo p; echo 1; echo ; echo ; echo w) | sudo fdisk /dev/xvdf"
    $ssh "sudo mkfs.ext4 /dev/xvdf1 ; sudo mkdir -p /var/lib/docker ; sudo su -c \"echo '/dev/xvdf1  /var/lib/docker  auto  defaults,auto  0  0' >> /etc/fstab\" ; sudo mount /var/lib/docker"

    echo "INFO: Configure additional interface for cloud VM"
    eni_id=`aws ${AWS_FLAGS} ec2 create-network-interface --subnet-id $subnet_ext_id --query 'NetworkInterface.NetworkInterfaceId' --output text`
    eni_attach_id=`aws ${AWS_FLAGS} ec2 attach-network-interface --network-interface-id $eni_id --instance-id $instance_id --device-index 1 --query 'AttachmentId' --output text`
    aws ${AWS_FLAGS} ec2 modify-network-interface-attribute --network-interface-id $eni_id --attachment AttachmentId=$eni_attach_id,DeleteOnTermination=true
    echo "INFO: additional interface $eni_id is attached: $eni_attach_id"
    sleep 20
    $ssh "$IFCONFIG_PATH/ifconfig" 2>/dev/null | grep -A 1 "^[a-z].*" | grep -v "\-\-"
  fi

  echo "INFO: Update packages on machine and install additional packages $(date)"
  if [[ "$ENVIRONMENT_OS" == 'centos' ]]; then
    $ssh "sudo yum install -y epel-release &>>yum.log"
    $ssh "sudo yum install -y mc git wget ntp ntpdate iptables iproute libxml2-utils python2.7 &>>yum.log"
    $ssh "sudo systemctl enable ntpd.service && sudo systemctl start ntpd.service"
  elif [[ "$ENVIRONMENT_OS" == 'ubuntu' ]]; then
    $ssh "sudo apt-get -y update &>>$HOME/apt.log"
    $ssh 'DEBIAN_FRONTEND=noninteractive sudo -E apt-get -fy -o Dpkg::Options::="--force-confnew" upgrade &>>$HOME/apt.log'
    $ssh "sudo apt-get install -y --no-install-recommends mc git wget ntp ntpdate libxml2-utils python2.7 &>>$HOME/apt.log"
  fi
}

# instance for OpenStack cloud
run_instance c4.4xlarge cloud true

# instance for build
run_instance m4.xlarge build false

trap - ERR EXIT

echo "INFO: Environment ready"
