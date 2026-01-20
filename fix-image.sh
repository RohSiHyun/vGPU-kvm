#!/bin/bash -e


echo "[+] Installing libguestfs-tools..."
sudo apt update
sudo apt install -y libguestfs-tools

IMG="images/ubuntu2404.qcow2"

if [ ! -f "$IMG" ]; then
    echo "[-] Image not found: $IMG"
    exit 1
fi

cat > /tmp/99-qemu-net.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    ens3:
      dhcp4: true
      dhcp-identifier: mac
    ens4:
      dhcp4: true
      dhcp-identifier: mac
    enp0s3:
      dhcp4: true
      dhcp-identifier: mac
    enp1s0:
      dhcp4: true
      dhcp-identifier: mac
NETPLAN

echo "[+] Configuring image..."
sudo virt-customize -a "$IMG" \
    --root-password password:root \
    --run-command 'id ubuntu || useradd -m -s /bin/bash -G sudo ubuntu' \
    --password ubuntu:password:ubuntu \
    --run-command 'sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config' \
    --run-command 'sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config' \
    --mkdir /etc/ssh/sshd_config.d \
    --run-command 'echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/99-allow-password.conf' \
    --run-command 'echo "PermitRootLogin yes" >> /etc/ssh/sshd_config.d/99-allow-password.conf' \
    --run-command 'systemctl enable ssh' \
    --run-command 'systemctl enable systemd-networkd' \
    --upload /tmp/99-qemu-net.yaml:/etc/netplan/99-qemu-net.yaml \
    --run-command 'chmod 600 /etc/netplan/99-qemu-net.yaml' \
    --run-command 'rm -f /etc/netplan/50-cloud-init.yaml' \
    --run-command 'echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu' \
    --run-command 'chmod 440 /etc/sudoers.d/ubuntu' \
    --run-command 'systemctl disable systemd-networkd-wait-online.service || true' \
    --firstboot-command 'netplan apply'

rm -f /tmp/99-qemu-net.yaml

echo ""
echo "[+] Done! Credentials:"
echo "    ubuntu / ubuntu"
echo "    root / root"
echo ""
echo "[+] Now run: ./launch.sh"
