# jib
Original script https://github.com/freebsd/freebsd-src/tree/main/share/examples/jails

My version of jib doesn't manage if_bridges and doesn't require a physical NIC

## usage
create an epair NAME and add to bridge BRIDGE
```
jib addm BRIDGE NAME
```
