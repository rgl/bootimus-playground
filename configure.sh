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

bootloader_upload
