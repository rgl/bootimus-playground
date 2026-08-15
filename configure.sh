#!/usr/bin/bash
set -euo pipefail

function bootloader_upload {
    pushd ipxe
    for n in artifacts-{amd64,arm64}; do
        rm -rf "$n"
        docker build --target="$n" --output=type=local,dest="$n" .
        chmod 755 "$n"
    done
    popd

    local bootloader_name='ipxe'

    # delete the existing bootloader (when it exists).
    curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X GET \
        "$bootimus_api_url/bootloaders" \
        | jq -r --arg n "$bootloader_name" '.data.sets[] | select(.name == $n) | .name' \
        | while read name; do
            echo "Deleting the existing $name bootloader..."
            local result="$(curl \
                --silent \
                --show-error \
                -H "Authorization: Bearer $bootimus_admin_token" \
                -X DELETE \
                "$bootimus_api_url/bootloaders/delete" \
                --url-query "set=$name")"
            if [ "$(jq -r .success <<<"$result")" != "true" ]; then
                echo "ERROR: failed to delete bootloader: $(jq . <<<"$result")"
                return 1
            fi
        done

    # create the bootloader.
    echo "Creating the $bootloader_name bootloader..."
    local result="$(curl \
        --silent \
        --show-error \
        -X POST \
        "$bootimus_api_url/bootloaders/create" \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -H 'Content-Type: application/json' \
        -d "$(jq \
            --null-input \
            --arg n "$bootloader_name" \
            '{name: $n}')")"
    if [ "$(jq -r .success <<<"$result")" != "true" ]; then
        echo "ERROR: failed to create bootloader: $(jq . <<<"$result")"
        return 1
    fi

    find ipxe/manifest.json ipxe/artifacts-* -type f | while read -r bootloader_file; do
        echo "Uploading the $bootloader_name bootloader $bootloader_file file..."
        local result="$(curl \
            --silent \
            --show-error\
            -H "Authorization: Bearer $bootimus_admin_token" \
            -X POST \
            "$bootimus_api_url/bootloaders/upload"  \
            -F "set=$bootloader_name" \
            -F "file=@$bootloader_file")"
        if [ "$(jq -r .success <<<"$result")" != "true" ]; then
            echo "ERROR: failed to upload bootloader file: $(jq . <<<"$result")"
            return 1
        fi
    done

    # set as the active bootloader.
    echo "Setting the $bootloader_name bootloader as the active bootloader..."
    local result="$(curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X POST \
        "$bootimus_api_url/bootloaders/select" \
        -H 'Content-Type: application/json' \
        -d "$(jq \
            --null-input \
            --arg n "$bootloader_name" \
            '{set: $n}')")"
    if [ "$(jq -r .success <<<"$result")" != "true" ]; then
        echo "ERROR: failed to set the active bootloader: $(jq . <<<"$result")"
        return 1
    fi
}

function qemu_drivers_download {
    # see https://docs.fedoraproject.org/en-US/quick-docs/creating-windows-virtual-machines-using-virtio-drivers/index.html
    # see https://github.com/virtio-win/virtio-win-guest-tools-installer
    # see https://github.com/virtio-win/virtio-win-pkg-scripts
    local u='https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso'
    local f="$(basename "$u")"
    if [ ! -f "qemu-drivers/$f" ]; then
        rm -rf qemu-drivers qemu-drivers.tmp
        mkdir qemu-drivers.tmp
        wget --progress=dot:giga -P qemu-drivers.tmp "$u"
        7z x -oqemu-drivers.tmp qemu-drivers.tmp/virtio-win-*.iso
        pushd qemu-drivers.tmp
            mkdir qemu-drivers-windows-server-2025-amd64
            pushd qemu-drivers-windows-server-2025-amd64
                for d in NetKVM vioscsi vioserial viostor; do
                    rsync \
                        -av \
                        --mkpath \
                        "../$d/2k25/amd64/" \
                        "$d/"
                done
                find . -type f \( -name '*.md' -o -name '*.pdb' \) -delete
                zip -9 -r ../qemu-drivers-windows-server-2025-amd64.zip *
            popd
            mkdir qemu-drivers-windows-11-amd64
            pushd qemu-drivers-windows-11-amd64
                for d in NetKVM vioscsi vioserial viostor; do
                    rsync \
                        -av \
                        --mkpath \
                        "../$d/w11/amd64/" \
                        "$d/"
                done
                find . -type f \( -name '*.md' -o -name '*.pdb' \) -delete
                zip -9 -r ../qemu-drivers-windows-11-amd64.zip *
            popd
        popd
        mv qemu-drivers.tmp qemu-drivers
    fi
}

# NB at the winpe command prompt, you can manually load drivers using, e.g.:
#       cd x:\drivers
#       drvload netkvm.inf
#       ipconfig /all
#       drvload vioscsi.inf
#       wmic diskdrive list brief
function qemu_drivers_upload {
    local image_name="$1-amd64"
    local image_file="$image_name.iso"
    local drivers_file="qemu-drivers-$image_name.zip"

    qemu_drivers_download

    local result="$(curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X GET \
        "$bootimus_api_url/images" \
        --url-query "filename=$image_file")"
    if [ "$(jq -r .success <<<"$result")" != "true" ]; then
        echo "ERROR: failed to get image: $(jq . <<<"$result")"
        return 1
    fi
    local image_id="$(jq -r .data.id <<<"$result")"

    # delete the existing drivers (when they exists).
    curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X GET \
        "$bootimus_api_url/drivers" \
        --url-query "imageId=$image_id" \
        | jq -r --arg f "$drivers_file" '.data[] | select(.filename == $f) | .id' \
        | while read id; do
            echo "Deleting the exiting drivers $id..."
            local result="$(curl \
                --silent \
                --show-error \
                -H "Authorization: Bearer $bootimus_admin_token" \
                -X DELETE \
                "$bootimus_api_url/drivers/delete" \
                --url-query "id=$id")"
            if [ "$(jq -r .success <<<"$result")" != "true" ]; then
                echo "ERROR: failed to delete drivers: $(jq . <<<"$result")"
                return 1
            fi
        done

    echo "Uploading the qemu drivers from qemu-drivers/$drivers_file to the $image_name ($image_id)..."
    local result="$(curl \
        --silent \
        --show-error\
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X POST \
        "$bootimus_api_url/drivers/upload"  \
        -F "imageId=$image_id" \
        -F "file=@qemu-drivers/$drivers_file" \
        -F "description=QEMU Drivers")"
    if [ "$(jq -r .success <<<"$result")" != "true" ]; then
        echo "ERROR: failed to upload drivers file: $(jq . <<<"$result")"
        return 1
    fi

    echo "Rebuilding the $image_name ($image_id) image in background..."
    local result="$(curl \
        --silent \
        --show-error\
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X POST \
        "$bootimus_api_url/drivers/rebuild"  \
        --url-query "imageId=$image_id")"
    if [ "$(jq -r .success <<<"$result")" != "true" ]; then
        echo "ERROR: failed to rebuild image: $(jq . <<<"$result")"
        return 1
    fi

    # TODO how to get api/drivers/rebuild result?
}

function image_upload {
    local image_name="$1"

    case "$image_name" in
        debian-13)
            # see https://www.debian.org
            local image_distro="debian"
            local image_url="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.6.0-amd64-netinst.iso"
            local image_file="debian-13-amd64.iso"
            local image_description="Debian 13 (Trixie)"
            local image_boot_params=""
            ;;
        ubuntu-server-26-04)
            # see https://ubuntu.com/server
            local image_distro="ubuntu"
            local image_url="https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso"
            local image_file="ubuntu-server-26-04-amd64.iso"
            local image_description="Ubuntu Server 26.04 (Resolute Raccoon)"
            local image_boot_params=""
            ;;
        fedora-server-44)
            # see https://fedoraproject.org/server/
            local image_distro="fedora"
            local image_url="https://download.fedoraproject.org/pub/fedora/linux/releases/44/Server/x86_64/iso/Fedora-Server-netinst-x86_64-44-1.7.iso"
            local image_file="fedora-server-44-amd64.iso"
            local image_description="Fedora Server 44"
            local image_boot_params="boot-params-fedora-server-44.txt"
            ;;
        almalinux-10)
            # see https://almalinux.org
            local image_distro="alma"
            local image_url="http://mirrors.ptisp.pt/almalinux/10/BaseOS/x86_64/os/images/boot.iso"
            local image_file="almalinux-10-amd64.iso"
            local image_description="AlmaLinux 10"
            local image_boot_params="boot-params-almalinux-10.txt"
            ;;
        windows-pe)
            # see https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-intro
            # see https://github.com/rgl/windows-pe-vagrant
            local image_distro="windows"
            local image_url="https://github.com/rgl/windows-pe-vagrant/releases/download/v20260727/windows-pe-20260727-amd64.iso"
            local image_file="windows-pe-amd64.iso"
            local image_description="Windows PE"
            local image_boot_params="boot-params-windows-pe.txt"
            ;;
        windows-server-2025)
            # see https://learn.microsoft.com/en-us/windows-server/
            # see https://github.com/rgl/windows-evaluation-isos-scraper/tree/main/data
            local image_distro="windows"
            local image_url="https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
            local image_file="windows-server-2025-amd64.iso"
            local image_description="Windows Server 2025"
            local image_boot_params="/dev/null"
            ;;
        windows-11)
            # see https://learn.microsoft.com/en-us/windows/whats-new/ltsc/overview
            # see https://github.com/rgl/windows-evaluation-isos-scraper/tree/main/data
            local image_distro="windows"
            local image_url="https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1742.240906-0331.ge_release_svc_refresh_CLIENT_LTSC_EVAL_x64FRE_en-us.iso"
            local image_file="windows-11-amd64.iso"
            local image_description="Windows 11"
            local image_boot_params="/dev/null"
            ;;
        *)
            echo "ERROR: unknown image name $image_name"
            ;;
    esac

    # delete the existing image (when it exists).
    curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X GET \
        "$bootimus_api_url/images" \
        --url-query "filename=$image_file" \
        | jq -r --arg f "$image_file" '.data | select(.filename == $f) | .filename' \
        | while read f; do
            echo "Deleting the exiting image $f..."
            local result="$(curl \
                --silent \
                --show-error \
                -H "Authorization: Bearer $bootimus_admin_token" \
                -X DELETE \
                "$bootimus_api_url/images" \
                --url-query "filename=$f" \
                --url-query "delete_file=true")"
            if [ "$(jq -r .success <<<"$result")" != "true" ]; then
                echo "ERROR: failed to delete image: $(jq . <<<"$result")"
                return 1
            fi
        done

    echo "Creating the $image_file ($image_description) image from $image_url..."
    local result="$(curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X POST \
        "$bootimus_api_url/images/download" \
        -H 'Content-Type: application/json' \
        -d "$(jq \
            --null-input \
            --arg u "$image_url" \
            --arg f "$image_file" \
            --arg d "$image_description" \
            '{url: $u, filename: $f, description: $d}')")"
    if [ "$(jq -r .success <<<"$result")" != "true" ]; then
        echo "ERROR: failed to create image: $(jq . <<<"$result")"
        return 1
    fi

    echo "Waiting for the $image_file ($image_description) image to be downloaded..."
    while true; do
        local image_progress="$(
            curl \
                --silent \
                --show-error \
                -H "Authorization: Bearer $bootimus_admin_token" \
                -X GET \
                "$bootimus_api_url/downloads/progress" \
                --url-query "filename=$image_file"
        )"
        local image_status="$(jq -r .data.status <<<"$image_progress")"
        case "$image_status" in
            downloading)
                echo -n "."
                sleep 5
                ;;
            completed)
                echo "download completed!"
                break
                ;;
            error)
                echo "ERROR: failed to download: $(jq -r .data.error <<<"$image_progress")"
                return 1
                break
                ;;
            *)
                echo "ERROR: failed to download: $(jq <<<"$image_progress")"
                return 1
                break
        esac
    done

    echo "The $image_file ($image_description) image was created as:"
    local result="$(curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X GET \
        "$bootimus_api_url/images" \
        --url-query "filename=$image_file")"
    if [ "$(jq -r .success <<<"$result")" != "true" ]; then
        echo "ERROR: failed to get image: $(jq . <<<"$result")"
        return 1
    fi
    jq -r .data <<<"$result"

    echo "Extracting the $image_file ($image_description) image..."
    local result="$(curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X POST \
        "$bootimus_api_url/images/extract" \
        --url-query "filename=$image_file" \
        -H 'Content-Type: application/json' \
        -d "{}")"
    if [ "$(jq -r .success <<<"$result")" != "true" ]; then
        echo "ERROR: failed to extract the image: $(jq . <<<"$result")"
        return 1
    fi

    # NB api/images/extract blocks, so the following is somewhat moot.
    echo "Waiting for the $image_file ($image_description) image extraction to finish..."
    while true; do
        local image_progress="$(
            curl \
                --silent \
                --show-error \
                -H "Authorization: Bearer $bootimus_admin_token" \
                -X GET \
                "$bootimus_api_url/images/extract-progress" \
                --url-query "filename=$image_file"
        )"
        local image_status="$(jq -r .data.status <<<"$image_progress")"
        case "$image_status" in
            extracting)
                echo -n "."
                sleep 5
                ;;
            done|idle)
                echo "extract completed!"
                break
                ;;
            error)
                echo "ERROR: $(jq -r .data.error <<<"$image_progress")"
                return 1
                break
                ;;
            *)
                echo "ERROR: unknown extract status: $(jq <<<"$image_progress")"
                return 1
                break
        esac
    done

    echo "Downloading the $image_file ($image_description) image netboot..."
    local result="$(curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X POST \
        "$bootimus_api_url/images/netboot/download" \
        --url-query "filename=$image_file" \
        -H 'Content-Type: application/json' \
        -d "{}")"
    if [ "$(jq -r .success <<<"$result")" != "true" ]; then
        if [ "$(jq -r .error <<<"$result")" != "Netboot download not required for this image" ]; then
            echo "ERROR: failed to download the image netboot: $(jq . <<<"$result")"
            return 1
        fi
    fi

    # set the boot params.
    if [ -r "$image_boot_params" ]; then
        echo "Setting the $image_file ($image_description) image boot params..."
        local result="$(curl \
            --silent \
            --show-error \
            -H "Authorization: Bearer $bootimus_admin_token" \
            -X PUT \
            "$bootimus_api_url/images" \
            --url-query "filename=$image_file" \
            -H "Content-Type: application/json" \
            -d "$(jq \
                --null-input \
                --rawfile b "$image_boot_params" \
                '{boot_params: $b}')")"
        if [ "$(jq -r .success <<<"$result")" != "true" ]; then
            echo "ERROR: failed to set the image boot params: $(jq . <<<"$result")"
            return 1
        fi
    fi
}

function client_configure {
    local client_image_name="$1"

    case "$client_image_name" in
        debian-13)
            local client_image="debian-13-amd64-netinst.iso"
            ;;
        ubuntu-server-26-04)
            local client_image="ubuntu-server-26-04-amd64.iso"
            ;;
        fedora-server-44)
            local client_image="fedora-server-44-amd64.iso"
            ;;
        almalinux-10)
            local client_image="almalinux-10-amd64.iso"
            ;;
        windows-pe)
            local client_image="windows-pe-amd64.iso"
            ;;
        windows-server-2025)
            local client_image="windows-server-2025-amd64.iso"
            ;;
        windows-11)
            local client_image="windows-11-amd64.iso"
            ;;
        *)
            echo "ERROR: unknown image name $client_image_name"
            return 1
            ;;
    esac

    local client_name="vm0"
    local client_mac="02:00:00:00:00:00"

    # delete the existing client (when it exists).
    curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X GET \
        "$bootimus_api_url/clients" \
        --url-query "mac=$client_mac" \
        | jq -r --arg n "$client_mac" '.data | select(.mac_address == $n) | .mac_address' \
        | while read client_mac; do
            echo "Deleting the exiting client $client_name ($client_mac)..."
            local result="$(curl \
                --silent \
                --show-error \
                -H "Authorization: Bearer $bootimus_admin_token" \
                -X DELETE \
                "$bootimus_api_url/clients" \
                --url-query "mac=$client_mac")"
            if [ "$(jq -r .success <<<"$result")" != "true" ]; then
                echo "ERROR: failed to delete the existing client: $(jq . <<<"$result")"
                return 1
            fi
        done

    echo "Creating the client $client_name ($client_mac)..."
    local result="$(curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X POST \
        "$bootimus_api_url/clients" \
        -H 'Content-Type: application/json' \
        -d "$(jq \
            --null-input \
            --arg m "$client_mac" \
            --arg n "$client_name" \
            '{mac_address: $m, name: $n}')")"
    if [ "$(jq -r .success <<<"$result")" != "true" ]; then
        echo "ERROR: failed to create the client: $(jq . <<<"$result")"
        return 1
    fi

    echo "Setting the client $client_name ($client_mac) next boot..."
    local result="$(curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X POST \
        "$bootimus_api_url/clients/next-boot" \
        -H 'Content-Type: application/json' \
        -d "$(jq \
            --null-input \
            --arg m "$client_mac" \
            --arg f "$client_image" \
            '{mac_address: $m, image_filename: $f}')")"
    if [ "$(jq -r .success <<<"$result")" != "true" ]; then
        echo "ERROR: failed to set the client next boot: $(jq . <<<"$result")"
        return 1
    fi

    echo "The client $client_name ($client_mac) was created as:"
    curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X GET \
        "$bootimus_api_url/clients" \
        --url-query "mac=$client_mac" \
        | jq -r .data
    #sudo sqlite3 data/bootimus.db "select mac_address,next_boot_image,auto_install_file from clients where mac_address='$client_mac'"
}

bootloader_upload

image_upload debian-13
image_upload ubuntu-server-26-04
image_upload fedora-server-44
image_upload almalinux-10
image_upload windows-pe
image_upload windows-server-2025 && qemu_drivers_upload windows-server-2025
image_upload windows-11 && qemu_drivers_upload windows-11

client_configure windows-11
