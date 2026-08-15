# About

My [Bootimus](https://github.com/garybowers/bootimus) playground.

## Usage (Ubuntu)

Install docker, libvirt, qemu, and terraform.

Verify that no other service is using the required ports:

```bash
#     67: BOOTP/DHCP/proxyDHCP server
#   4011: BOOTP/DHCP/proxyDHCP server
#     68: BOOTP/DHCP client
#     69: TFTP server
#   1445: SMB server
#  10809: NBD server
#   8080: bootimus http server
#   8081: bootimus admin server
sudo ss -anlp | grep -E ':(67|68|69|1445|4011|8080|8081|10809)\s+'
```

If the above returns any result, it means your machine already has a service
running that uses any of those ports and you need to stop them before starting
bootimus. For example, using:

```bash
sudo virsh net-destroy default # stop the network.
sudo systemctl stop smbd
```

Execute the bootimus server in foreground:

```bash
# NB the bootimus --windows-smb-port parameter is used to change the default
#    smb port from 445 to 1445, but it can only be accessed from windows 11 24H2
#    (or later) or windows server 2025 (or later). the port cannot be changed
#    on earlier windows versions.
# see https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-ports?tabs=command-line
# see https://bootimus.com/docs/deployment
# see https://github.com/garybowers/bootimus/releases
# see https://github.com/garybowers/bootimus/blob/v0.1.74/Dockerfile
# see https://hub.docker.com/r/garybowers/bootimus/tags
bootimus_image="garybowers/bootimus:0.1.74"
install -d data
docker run --rm "$bootimus_image" serve --help # show the help.
docker run \
    --rm \
    -it \
    --name bootimus \
    --net host \
    --volume ./data:/data \
    "$bootimus_image" \
        serve \
        --proxy-dhcp \
        --windows-smb \
        --windows-smb-port 1445
```

Switch to another shell.

Set the `admin` user password:

```bash
bootimus_admin_password='admin'
docker exec bootimus /bootimus user set-password admin --password "$bootimus_admin_password"
```

Access the Bootimus Admin Panel and login as the `admin` user:

```bash
xdg-open http://localhost:8081
```

Configure Bootimus:

```bash
bootimus_admin_token="$(curl \
    --silent \
    --show-error \
    -X POST \
    http://localhost:8081/api/login \
    -H 'Content-Type: application/json' \
    -d "$(jq \
        --null-input \
        --arg u admin \
        --arg p "$bootimus_admin_password" \
        '{username: $u, password: $p}')" \
    | jq -r .data.token)"

bootimus_admin_token="$bootimus_admin_token" \
    ./configure.sh
```

Show the Bootimus generated boot menu:

```bash
curl http://localhost:8080/menu.ipxe
```

Execute WireShark with one of the following capture filters:

* `ether host 02:00:00:00:00:00`
* `port 67 or port 68 or port 69 or port 8080`

Start a local virtual machine that boots from bootimus:

```bash
terraform init
terraform apply
```

And when you are ready, destroy everything:

```bash
terraform destroy
docker kill bootimus
sudo rm -rf data tmp
```

# Troubleshoot

Review the articles:

* [Windows Setup: Deployment Troubleshooting and Log Files](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/deployment-troubleshooting-and-log-files?view=windows-11).

Review the commands:

```bash
# inspect bootimus.
docker inspect bootimus | jq
docker exec bootimus ps -efww --forest
docker exec bootimus /bootimus serve --help

# confirm its serving our bootloader.
curl -s http://192.168.8.11:8080/wimboot | sha256sum
sha256sum ipxe/artifacts-amd64/amd64/wimboot

# verify that we can access the bootimus smb share.
docker exec bootimus cat /data/smb/smb.conf
smbclient --no-pass //192.168.8.11/windows-server-2025-amd64 --command 'ls sources/boot.wim'

# show information about the windows-pe boot.wim file.
docker exec bootimus wiminfo /data/isos/windows-pe-amd64/iso/sources/boot.wim
docker exec bootimus wimdir /data/isos/windows-pe-amd64/iso/sources/boot.wim | grep -i netkvm
docker exec bootimus wimdir /data/isos/windows-pe-amd64/iso/sources/boot.wim | grep -i winpeshl.ini
docker exec bootimus wimdir /data/isos/windows-pe-amd64/iso/sources/boot.wim | grep -i startnet.cmd
docker exec bootimus wimextract /data/isos/windows-pe-amd64/iso/sources/boot.wim 1 /Windows/System32/winpeshl.ini --to-stdout
docker exec bootimus wimextract /data/isos/windows-pe-amd64/iso/sources/boot.wim 1 /Windows/System32/startnet.cmd --to-stdout

# show information about the windows-server-2025 boot.wim file.
docker exec bootimus wiminfo /data/isos/windows-server-2025-amd64/iso/sources/boot.wim
docker exec bootimus wimdir /data/isos/windows-server-2025-amd64/iso/sources/boot.wim 2 | grep -i netkvm
docker exec bootimus wimdir /data/isos/windows-server-2025-amd64/iso/sources/boot.wim 2 | grep -i winpeshl.ini
docker exec bootimus wimdir /data/isos/windows-server-2025-amd64/iso/sources/boot.wim 2 | grep -i startnet.cmd
docker exec bootimus wimextract /data/isos/windows-server-2025-amd64/iso/sources/boot.wim 2 /Windows/System32/winpeshl.ini --to-stdout
docker exec bootimus wimextract /data/isos/windows-server-2025-amd64/iso/sources/boot.wim 2 /Windows/System32/startnet.cmd --to-stdout

# show the files differences between the two images inside the windows-server-2025 boot.wim file.
docker exec bootimus wimdir /data/isos/windows-server-2025-amd64/iso/sources/boot.wim 1 >windows-server-2025-amd64-1.txt
docker exec bootimus wimdir /data/isos/windows-server-2025-amd64/iso/sources/boot.wim 2 >windows-server-2025-amd64-2.txt
diff -u windows-server-2025-amd64-1.txt windows-server-2025-amd64-2.txt
rm windows-server-2025-amd64-1.txt windows-server-2025-amd64-2.txt

# show the windows distro profile.
sudo sqlite3 data/bootimus.db ".schema distro_profiles"
sudo sqlite3 data/bootimus.db "select * from distro_profiles where family='windows'"
#sudo sqlite3 data/bootimus.db "select profile_id,kernel_paths,default_boot_params from distro_profiles where family='windows'"
#sudo sqlite3 data/bootimus.db "update distro_profiles set kernel_paths='[]' where profile_id='windows'"

# show the windows images.
sudo sqlite3 data/bootimus.db ".schema images"
sudo sqlite3 data/bootimus.db "select * from images where distro='windows'"
#sudo sqlite3 data/bootimus.db "select name,boot_params from images where name='windows-server-2025-amd64'"
#sudo sqlite3 data/bootimus.db "update images set boot_params='' where name='windows-server-2025-amd64'"

# show the clients.
sudo sqlite3 data/bootimus.db ".schema clients"
sudo sqlite3 data/bootimus.db "select * from clients"
```
