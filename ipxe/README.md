Build the artifacts:

```bash
for n in artifacts-{amd64,arm64}; do
    rm -rf "$n"
    docker build --target="$n" --output=type=local,dest="$n" .
    chmod 755 "$n"
    find "$n" -type f
done
```
