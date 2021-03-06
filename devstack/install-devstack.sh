#!/bin/bash -ex

localrcfile=$1
ENV_FILE="cloudrc"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30"

source $ENV_FILE
SSH_DEST="ubuntu@$public_ip"
SSH="ssh -i kp $SSH_OPTS $SSH_DEST"
SCP="scp -i kp $SSH_OPTS"

rm -f stack.log

while [ $($SSH 'pwd > /dev/null' ; echo $?) != 0 ]; do
  sleep 5
done

echo -------------------------------------------------------------------------- $(date)
$SSH "sudo apt-get -qq update"
$SSH "sudo DEBIAN_FRONTEND=noninteractive apt-get -fqy -o Dpkg::Options::=\"--force-confnew\" upgrade"
$SSH "sudo reboot" || /bin/true

sleep 30
while [ $($SSH 'pwd > /dev/null' ; echo $?) != 0 ]; do
  sleep 5
done

echo -------------------------------------------------------------------------- $(date)
cat <<EOF | $SSH
set -ex
(echo o; echo n; echo p; echo 1; echo ; echo ; echo w) | sudo fdisk /dev/xvdh
sudo mkfs.ext4 /dev/xvdh1
sudo mkdir -p /opt/stack
sudo bash -c "echo '/dev/xvdh1  /opt/stack  auto  defaults,auto  0  0' >> /etc/fstab"
sudo mount /opt/stack
sudo chown \$USER /opt/stack

sudo sed -i 's/# deb/deb/g' /etc/apt/sources.list
sudo apt-get -qq update
sudo DEBIAN_FRONTEND=noninteractive apt-get -fqy install git ebtables bridge-utils

cd /opt/stack
git clone https://github.com/openstack/ec2api-tempest-plugin
git clone https://github.com/openstack-dev/devstack.git

sudo mkdir /var/log/journal || /bin/true
sudo mkdir /etc/systemd/journald.conf.d || /bin/true
sudo rm -f /etc/systemd/journald.conf.d/size.conf
echo [Journal] | sudo tee /etc/systemd/journald.conf.d/size.conf > /dev/null
echo SystemMaxUse=1G | sudo tee -a /etc/systemd/journald.conf.d/size.conf > /dev/null
echo RuntimeMaxUse=1G | sudo tee -a /etc/systemd/journald.conf.d/size.conf > /dev/null
echo Storage=persistent | sudo tee -a /etc/systemd/journald.conf.d/size.conf > /dev/null
sudo systemctl restart systemd-journald || true
EOF

echo -------------------------------------------------------------------------- $(date)
cp $localrcfile localrc
sed -i "s\^SERVICE_HOST.*$\SERVICE_HOST=$public_ip\m" localrc
$SCP localrc $SSH_DEST:/opt/stack/devstack/localrc
echo "Installing devstack"
$SSH "cd /opt/stack/devstack; ./stack.sh < /dev/null" &> stack.log
exit_code=$?
if [[ $exit_code != 0 ]]; then
  cat stack.log
  exit $exit_code
fi
echo -------------------------------------------------------------------------- $(date)
