#!/bin/bash -e


PORT=10022
IMG="ubuntu2404"
QEMU="$PWD/qemu/build/qemu-system-x86_64"
OVMF_CODE="$PWD/ovmf/OVMF_CODE_4M.fd"
OVMF_VARS="$PWD/ovmf/OVMF_VARS_4M.fd"

GPU=""
GPU_AUDIO=""

VGPU_UUID=""

MEMORY="16G"
CPUS="8"

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -g <pci_id>      GPU PCI ID for passthrough (e.g., 0000:81:00.0)"
    echo "  -a <pci_id>      GPU Audio PCI ID (e.g., 0000:81:00.1)"
    echo "  -v <uuid>        vGPU UUID (for NVIDIA vGPU)"
    echo "  -m <memory>      Memory size (default: 16G)"
    echo "  -c <cpus>        Number of CPUs (default: 8)"
    echo "  -p <port>        SSH port (default: 10022)"
    echo "  -d               Enable GDB debugging (-s -S)"
    echo "  -i               Enable IOMMU"
    echo "  -n               No GPU (software rendering)"
    echo "  -s               Use SPICE display instead of VNC"
    echo "  -h               Show this help"
    echo ""
    echo "Examples:"
    echo "  # GPU Passthrough"
    echo "  $0 -g 0000:81:00.0 -a 0000:81:00.1"
    echo ""
    echo "  # vGPU (NVIDIA)"
    echo "  $0 -v 12345678-1234-1234-1234-123456789abc"
    echo ""
    echo "  # No GPU (software rendering)"
    echo "  $0 -n"
    echo ""
    echo "  # With debugging"
    echo "  DEBUG=1 $0 -g 0000:81:00.0"
    exit 1
}

ENABLE_DEBUG=""
ENABLE_IOMMU=""
NO_GPU=""
USE_SPICE=""

while getopts ":hg:a:v:m:c:p:dins" opt; do
    case $opt in
        h)
            usage
            ;;
        g)
            GPU=$OPTARG
            ;;
        a)
            GPU_AUDIO=$OPTARG
            ;;
        v)
            VGPU_UUID=$OPTARG
            ;;
        m)
            MEMORY=$OPTARG
            ;;
        c)
            CPUS=$OPTARG
            ;;
        p)
            PORT=$OPTARG
            ;;
        d)
            ENABLE_DEBUG="1"
            ;;
        i)
            ENABLE_IOMMU="1"
            ;;
        n)
            NO_GPU="1"
            ;;
        s)
            USE_SPICE="1"
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

[ -n "$DEBUG" ] && ENABLE_DEBUG="1"
[ -n "$IOMMU" ] && ENABLE_IOMMU="1"

if [ ! -f "$QEMU" ]; then
    echo "[-] QEMU not found at: $QEMU"
    echo "    Trying system QEMU..."
    QEMU=$(which qemu-system-x86_64 2>/dev/null || true)
    if [ -z "$QEMU" ]; then
        echo "[-] qemu-system-x86_64 not found. Please run setup.sh first."
        exit 1
    fi
fi

if [ ! -f "images/${IMG}.qcow2" ]; then
    echo "[-] Image not found: images/${IMG}.qcow2"
    echo "    Please run: ./setup.sh -t image"
    exit 1
fi

if [ ! -f "$OVMF_CODE" ] || [ ! -f "$OVMF_VARS" ]; then
    echo "[!] OVMF not found, using system OVMF..."
    if [ -f "/usr/share/OVMF/OVMF_CODE_4M.fd" ]; then
        OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
        OVMF_VARS="/usr/share/OVMF/OVMF_VARS_4M.fd"
    else
        echo "[-] OVMF not found. Please run: ./setup.sh -t ovmf"
        exit 1
    fi
fi


debug_str=""
if [ -n "$ENABLE_DEBUG" ]; then
    debug_str="-s -S"
    echo "[+] GDB debugging enabled. Connect with: gdb -ex 'target remote :1234'"
fi

iommu_str=""
machine_iommu=""
if [ -n "$ENABLE_IOMMU" ]; then
    machine_iommu=",kernel_irqchip=split"
    iommu_str="-device intel-iommu,intremap=on,device-iotlb=on"
    echo "[+] IOMMU enabled"
fi

gpu_str=""
display_str="-display gtk"

if [ -n "$NO_GPU" ]; then
    gpu_str="-device virtio-vga-gl -display gtk,gl=on"
    echo "[+] Using software rendering (virtio-vga-gl)"

elif [ -n "$VGPU_UUID" ]; then
    gpu_str="-device vfio-pci,sysfsdev=/sys/bus/mdev/devices/${VGPU_UUID}"
    display_str="-vga none -display none"
    echo "[+] Using NVIDIA vGPU: ${VGPU_UUID}"

elif [ -n "$GPU" ]; then
    display_str="-vga none -display none"
    echo "[+] Using GPU Passthrough: ${GPU}"
    
    if [ -n "$GPU_AUDIO" ]; then
        gpu_str="${gpu_str} -device vfio-pci,host=${GPU_AUDIO}"
        echo "[+] GPU Audio: ${GPU_AUDIO}"
    fi
else
    gpu_str="-device qxl-vga,vgamem_mb=64"
    echo "[+] Using QXL VGA (default)"
fi

if [ -n "$USE_SPICE" ]; then
    display_str="-display none -spice port=5900,disable-ticketing=on"
    gpu_str="-device qxl-vga,vgamem_mb=128"
    echo "[+] SPICE enabled on port 5900"
    echo "    Connect with: remote-viewer spice://localhost:5900"
fi

cloud_init_str=""
if [ -f "images/cloud-init.iso" ]; then
    cloud_init_str="-cdrom images/cloud-init.iso"
fi

echo ""
echo "========================================"
echo "Starting Ubuntu 24.04 VM"
echo "========================================"
echo "Memory: ${MEMORY}"
echo "CPUs: ${CPUS}"
echo "SSH Port: ${PORT}"
echo "Image: images/${IMG}.qcow2"
echo "========================================"
echo ""
echo "SSH: ssh -p ${PORT} ubuntu@localhost"
echo "Default password: ubuntu"
echo ""


sudo $QEMU \
  -cpu host \
  -machine q35,accel=kvm,kernel_irqchip=split \
  -enable-kvm \
  -m 32g \
  -smp 8 \
  -uuid 13486104-b2ea-4151-a5ad-5b580cbd871a \
  -drive if=pflash,format=raw,readonly=on,file=./ovmf/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=./ovmf/OVMF_VARS_4M.fd \
  -drive file=images/${IMG}.qcow2,if=virtio,format=qcow2,cache=none,aio=native \
  -cdrom images/cloud-init.iso \
  -device ioh3420,id=pcie.0,chassis=1 \
  -device vfio-pci,sysfsdev=/sys/bus/pci/devices/0000:81:00.4 \
  -device virtio-net-pci,bus=pcie.0,netdev=net0,disable-legacy=on,disable-modern=off,iommu_platform=on,ats=on \
  -netdev user,id=net0,host=10.0.2.10,hostfwd=tcp::${PORT}-:22 \
  -device virtio-serial-pci,disable-modern=false,id=serial0 \
  -device virtconsole,chardev=charconsole0,id=console0 \
  -chardev socket,id=charconsole0,path=virtconsole.sock,server=on,wait=off \
  -vga none -display none \
  ${iommu_str} \
  -nographic \
  -s -S
