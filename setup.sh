#!/bin/bash -e


run_cmd()
{
    echo "[+] $*"
    eval "$*" || {
        echo "[-] ERROR: $*"
        exit 1
    }
}

build_qemu()
{
    echo "========================================"
    echo "[+] Building QEMU..."
    echo "========================================"

    NUM_CORES=$(nproc)
    MAX_CORES=$(($NUM_CORES - 1))

    run_cmd sudo apt update
    run_cmd sudo apt install -y \
        git libglib2.0-dev libfdt-dev libpixman-1-dev zlib1g-dev ninja-build \
        libaio-dev libbluetooth-dev libcapstone-dev libbrlapi-dev libbz2-dev \
        libcap-ng-dev libcurl4-gnutls-dev libgtk-3-dev \
        libibverbs-dev libjpeg8-dev libncurses5-dev libnuma-dev \
        librbd-dev librdmacm-dev \
        libsasl2-dev libsdl2-dev libseccomp-dev libsnappy-dev libssh-dev \
        libvde-dev libvdeplug-dev libvte-2.91-dev liblzo2-dev \
        valgrind xfslibs-dev libslirp-dev

    [ -d qemu ] || {
        run_cmd wget https://download.qemu.org/qemu-8.2.2.tar.xz
        run_cmd tar xvJf qemu-8.2.2.tar.xz
        run_cmd rm qemu-8.2.2.tar.xz
        run_cmd mv qemu-8.2.2 qemu
    }

    mkdir -p qemu/build
    pushd qemu/build > /dev/null
    ../configure --target-list=x86_64-softmmu --enable-slirp --disable-werror
    make -j$MAX_CORES
    popd > /dev/null

    echo "[+] QEMU build complete: $PWD/qemu/build/qemu-system-x86_64"
}

build_image()
{
    local size=${1:-"40G"}

    echo "========================================"
    echo "[+] Creating Ubuntu 24.04 image..."
    echo "========================================"

    mkdir -p images

    local cloud_img="ubuntu-24.04-server-cloudimg-amd64.img"
    #local cloud_img="ubuntu-24.04-server-cloudimg-amd64-disk-kvm.img"
    local img_url="https://cloud-images.ubuntu.com/releases/noble/release/${cloud_img}"

    [ -f "images/${cloud_img}" ] || {
        echo "[+] Downloading Ubuntu 24.04 cloud image..."
        run_cmd wget -O "images/${cloud_img}" "${img_url}"
    }

    [ -f "images/ubuntu2404.qcow2" ] || {
        run_cmd cp "images/${cloud_img}" "images/ubuntu2404.qcow2"
        run_cmd qemu-img resize "images/ubuntu2404.qcow2" ${size}
    }

    create_cloud_init

    echo "[+] Image created: images/ubuntu2404.qcow2"
}

create_cloud_init()
{
    echo "[+] Creating cloud-init configuration..."

    mkdir -p images

    cat > images/user-data << 'EOF'
hostname: ubuntu-vm
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo, adm, video, render
    shell: /bin/bash
    lock_passwd: false
    passwd: $6$rounds=4096$xyz$ghCj1A3oSEgOjFQBe.O5suMqq1VhB7JJQJW8kLCdFyXJJmXYP1UXTkf1g9d5eVF0H0FQY5wLGZNJE7xvE5BX41

ssh_pwauth: true
disable_root: false

package_update: true
package_upgrade: true

packages:
  - build-essential
  - linux-headers-generic
  - dkms
  - pkg-config
  - libglvnd-dev
  - qemu-guest-agent
  - net-tools
  - vim

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
EOF

    cat > images/meta-data << 'EOF'
instance-id: ubuntu-vm-001
local-hostname: ubuntu-vm
EOF

    run_cmd sudo apt install -y cloud-image-utils
    run_cmd cloud-localds images/cloud-init.iso images/user-data images/meta-data

    echo "[+] Cloud-init ISO created: images/cloud-init.iso"
}

setup_vfio()
{
    echo "========================================"
    echo "[+] Setting up VFIO for GPU Passthrough..."
    echo "========================================"

    run_cmd sudo apt install -y linux-headers-$(uname -r)

    cat << 'EOF' | sudo tee /etc/modules-load.d/vfio.conf
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
EOF

    if ! grep -q "intel_iommu=on" /etc/default/grub && ! grep -q "amd_iommu=on" /etc/default/grub; then
        echo "[!] IOMMU not enabled in GRUB. Adding IOMMU parameters..."
        
        if grep -q "GenuineIntel" /proc/cpuinfo; then
            IOMMU_PARAM="intel_iommu=on iommu=pt"
        else
            IOMMU_PARAM="amd_iommu=on iommu=pt"
        fi

        sudo sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"${IOMMU_PARAM} /g" /etc/default/grub
        run_cmd sudo update-grub

        echo "[!] GRUB updated. Please reboot the system."
    fi

    cat << 'SCRIPT' > bind-vfio.sh

if [ -z "$1" ]; then
    echo "Usage: $0 <PCI_ID>"
    echo "Example: $0 0000:81:00.0"
    echo ""
    echo "Available GPUs:"
    lspci -nn | grep -i 'vga\|3d\|display'
    exit 1
fi

PCI_ID=$1

if [ -e /sys/bus/pci/devices/${PCI_ID}/driver ]; then
    echo "[+] Unbinding current driver..."
    echo ${PCI_ID} | sudo tee /sys/bus/pci/devices/${PCI_ID}/driver/unbind
fi

VENDOR_ID=$(cat /sys/bus/pci/devices/${PCI_ID}/vendor)
DEVICE_ID=$(cat /sys/bus/pci/devices/${PCI_ID}/device)

echo "[+] Binding to vfio-pci (${VENDOR_ID} ${DEVICE_ID})..."
echo "vfio-pci" | sudo tee /sys/bus/pci/devices/${PCI_ID}/driver_override
echo ${PCI_ID} | sudo tee /sys/bus/pci/drivers/vfio-pci/bind

echo "[+] Done. Device ${PCI_ID} is now bound to vfio-pci"
SCRIPT
    chmod +x bind-vfio.sh

    echo ""
    echo "[+] VFIO setup complete!"
    echo "[+] To bind a GPU to VFIO, run: ./bind-vfio.sh <PCI_ID>"
    echo "[+] Example: ./bind-vfio.sh 0000:81:00.0"
    echo ""
    echo "[!] Available GPUs:"
    lspci -nn | grep -i 'vga\|3d\|display' || true
}

setup_ovmf()
{
    echo "========================================"
    echo "[+] Setting up OVMF (UEFI firmware)..."
    echo "========================================"

    run_cmd sudo apt install -y ovmf

    mkdir -p ovmf

    run_cmd cp /usr/share/OVMF/OVMF_CODE_4M.fd ovmf/
    run_cmd cp /usr/share/OVMF/OVMF_VARS_4M.fd ovmf/

    echo "[+] OVMF setup complete: ovmf/OVMF_CODE.fd, ovmf/OVMF_VARS.fd"
}

usage() {
    echo "Usage: $0 [-t <target>] [-s <image_size>]"
    echo ""
    echo "Options:"
    echo "  -t <target>      Target to run (default: all)"
    echo "                   - all: Run all setup steps"
    echo "                   - qemu: Build QEMU only"
    echo "                   - image: Create Ubuntu 24.04 image only"
    echo "                   - vfio: Setup VFIO for GPU passthrough"
    echo "                   - ovmf: Setup OVMF (UEFI firmware)"
    echo "                   - guide: Print vGPU installation guide"
    echo ""
    echo "  -s <size>        Image size (default: 40G)"
    echo ""
    echo "Examples:"
    echo "  $0                    # Run all setup steps"
    echo "  $0 -t qemu            # Build QEMU only"
    echo "  $0 -t image -s 60G    # Create 60GB image"
    exit 1
}

target="all"
image_size="40G"

while getopts ":ht:s:" opt; do
    case $opt in
        h)
            usage
            ;;
        t)
            target=$OPTARG
            ;;
        s)
            image_size=$OPTARG
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            usage
            ;;
    esac
done

echo "========================================"
echo "Ubuntu 24.04 QEMU vGPU Setup"
echo "Target: $target"
echo "Image Size: $image_size"
echo "========================================"

case $target in
    "all")
        build_qemu
        build_image ${image_size}
        setup_ovmf
        setup_vfio
        ;;
    "qemu")
        build_qemu
        ;;
    "image")
        build_image ${image_size}
        ;;
    "vfio")
        setup_vfio
        ;;
    "ovmf")
        setup_ovmf
        ;;
    *)
        echo "Unknown target: $target"
        usage
        ;;
esac

echo ""
echo "========================================"
echo "[+] Setup complete!"
echo "========================================"
