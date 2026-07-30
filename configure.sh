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
        http://localhost:8081/api/bootloaders \
        | jq -r --arg n "$bootloader_name" '.data.sets[] | select(.name == $n) | .name' \
        | while read name; do
            echo "Deleting the existing $name bootloader..."
            local result="$(curl \
                --silent \
                --show-error \
                -H "Authorization: Bearer $bootimus_admin_token" \
                -X DELETE \
                http://localhost:8081/api/bootloaders/delete \
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
        http://localhost:8081/api/bootloaders/create \
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
            http://localhost:8081/api/bootloaders/upload  \
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
        http://localhost:8081/api/bootloaders/select \
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

function image_upload {
    local image_name="$1"

    case "$image_name" in
        windows-pe)
            local image_distro="windows"
            local image_url="https://github.com/rgl/windows-pe-vagrant/releases/download/v20260727/windows-pe-20260727-amd64.iso"
            local image_file="windows-pe-amd64.iso"
            local image_description="Windows PE"
            local image_boot_params="boot-params-windows-pe.txt"
            ;;
        windows-server-2025)
            local image_distro="windows"
            # see https://github.com/rgl/windows-evaluation-isos-scraper/tree/main/data
            local image_url="https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
            local image_file="windows-server-2025-amd64.iso"
            local image_description="Windows Server 2025"
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
        http://localhost:8081/api/images \
        --url-query "filename=$image_file" \
        | jq -r --arg f "$image_file" '.data | select(.filename == $f) | .filename' \
        | while read f; do
            echo "Deleting the exiting image $f..."
            local result="$(curl \
                --silent \
                --show-error \
                -H "Authorization: Bearer $bootimus_admin_token" \
                -X DELETE \
                http://localhost:8081/api/images \
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
        http://localhost:8081/api/images/download \
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
                http://localhost:8081/api/downloads/progress \
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
        http://localhost:8081/api/images \
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
        http://localhost:8081/api/images/extract \
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
                http://localhost:8081/api/images/extract-progress \
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

    # set the boot params.
    if [ -r "$image_boot_params" ]; then
        echo "Setting the $image_file ($image_description) image boot params..."
        local result="$(curl \
            --silent \
            --show-error \
            -H "Authorization: Bearer $bootimus_admin_token" \
            -X PUT \
            http://localhost:8081/api/images \
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
        windows-pe)
            local client_image="windows-pe-amd64.iso"
            ;;
        windows-server-2025)
            local client_image="windows-server-2025-amd64.iso"
            ;;
        *)
            echo "ERROR: unknown image name $client_image_name"
            return 1
            ;;
    esac

    local client_name="vm0"
    local client_mac="02:00:00:00:00:00"

    # delete the existing client (when it exists).
    # TODO unfortunately we cannot yet delete the client. currently, the client
    #      is not really deleted, its just soft-deleted, which prevents a new
    #      one to be created, so do not ever delete it.
    #      drop this after https://github.com/garybowers/bootimus/issues/103 is resolved.
    curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X GET \
        http://localhost:8081/api/clients \
        --url-query "mac=$client_mac" \
        | jq -r --arg n "$client_mac" '.data | select(.mac_address == $n) | .mac_address' \
        | while read client_mac; do
            # TODO drop this after https://github.com/garybowers/bootimus/issues/103 is resolved.
            continue
            echo "Deleting the exiting client $client_name ($client_mac)..."
            local result="$(curl \
                --silent \
                --show-error \
                -H "Authorization: Bearer $bootimus_admin_token" \
                -X DELETE \
                http://localhost:8081/api/clients \
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
        http://localhost:8081/api/clients \
        -H 'Content-Type: application/json' \
        -d "$(jq \
            --null-input \
            --arg m "$client_mac" \
            --arg n "$client_name" \
            '{mac_address: $m, name: $n}')")"
    if [ "$(jq -r .success <<<"$result")" != "true" ]; then
        # TODO drop this after https://github.com/garybowers/bootimus/issues/103 is resolved.
        if [ "$(jq -r .error <<<"$result")" != "constraint failed: UNIQUE constraint failed: clients.mac_address (2067)" ]; then
            echo "ERROR: failed to create the client: $(jq . <<<"$result")"
            return 1
        fi
    fi

    echo "Setting the client $client_name ($client_mac) next boot..."
    local result="$(curl \
        --silent \
        --show-error \
        -H "Authorization: Bearer $bootimus_admin_token" \
        -X POST \
        http://localhost:8081/api/clients/next-boot \
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
        http://localhost:8081/api/clients \
        --url-query "mac=$client_mac" \
        | jq -r .data
    #sudo sqlite3 data/bootimus.db "select mac_address,next_boot_image,auto_install_file from clients where mac_address='$client_mac'"
}

bootloader_upload

image_upload windows-pe
image_upload windows-server-2025

client_configure windows-server-2025
