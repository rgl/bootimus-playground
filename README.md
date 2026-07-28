# About

My [Bootimus](https://github.com/garybowers/bootimus) playground.

## Usage (Ubuntu)

Install ubuntu, docker, libvirt, and qemu.

Verify that no other service is using the required ports:

```bash
#     67: BOOTP/DHCP/proxyDHCP server
#   4011: BOOTP/DHCP/proxyDHCP server
#     68: BOOTP/DHCP client
#     69: TFTP server
#  10809: NBD server
#   8080: bootimus http server
#   8081: bootimus admin server
sudo ss -anlp | grep -E ':(67|68|69|4011|8080|8081|10809)\s+'
```

If the above returns any result, it means your machine already has a service
running that uses any of those ports and you need to stop them before starting
bootimus. For example, using:

```bash
sudo virsh net-destroy default # stop the network.
```

Execute the bootimus server in foreground:

```bash
# see https://bootimus.com/docs/deployment
# see https://github.com/garybowers/bootimus/releases
# see https://github.com/garybowers/bootimus/blob/v0.1.73/Dockerfile
# see https://hub.docker.com/r/garybowers/bootimus/tags
bootimus_image="garybowers/bootimus:0.1.73"
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
        --proxy-dhcp
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

Show the Bootimus generated boot menu:

```bash
curl http://localhost:8080/menu.ipxe
```

And when you are ready, destroy everything:

```bash
docker kill bootimus
sudo rm -rf data tmp
```

# Troubleshoot

Review the commands:

```bash
# inspect bootimus.
docker inspect bootimus | jq
docker exec bootimus ps -efww --forest
docker exec bootimus /bootimus serve --help
```
