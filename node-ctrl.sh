#!/bin/bash

#set -x
CONFDIR="/home/ubuntu/conf"
MCBINDIR="/home/ubuntu/bin/memcached"
ARG=${@:3}

host="$2"
if [ $1 == "startdbg" ] ; then
    lxc exec $host -- sh -c "LUA_PATH=\"$CONFDIR/?.lua;;\" $MCBINDIR/memcached-debug -c 30000 -u ubuntu -d -P /tmp/memcached.pid $ARG"
elif [ $1 == "start" ] ; then
    lxc exec $host -- sh -c "LUA_PATH=\"$CONFDIR/?.lua;;\" $MCBINDIR/memcached -c 30000 -u ubuntu -d -P /tmp/memcached.pid $ARG"
elif [ $1 == "startraw" ] ; then
    lxc exec $host -- sh -c "$CONFDIR/$ARG"
elif [ $1 == "stop" ] ; then
    lxc exec $host -- sh -c "kill \`cat /tmp/memcached.pid\`"
elif [ $1 == "bwlimit" ] ; then
    VETH=`lxc config get $host volatile.eth0.host_name`
    sudo tc qdisc add dev $VETH handle 1:0 root htb default 10
    sudo tc class add dev $VETH parent 1:0 classid 1:10 htb rate 500Mbit
    sudo tc filter add dev $VETH parent 1:0 protocol all u32 match u32 0 0 flowid 1:1
    sudo tc qdisc add dev $VETH handle ffff:0 ingress
    sudo tc filter add dev $VETH parent ffff:0 protocol all u32 match u32 0 0 police rate 500Mbit burst 1024k mtu 64kb drop
elif [ $1 == "nobwlimit" ] ; then
    VETH=`lxc config get $host volatile.eth0.host_name`
    sudo tc qdisc del dev $VETH root
    sudo tc qdisc del dev $VETH ingress
elif [ $1 == "delay" ] ; then
    lxc exec $host -- tc qdisc add dev eth0 root netem delay $3
elif [ $1 == "ploss" ] ; then
    lxc exec $host -- tc qdisc add dev eth0 root netem loss $3
elif [ $1 == "clear" ] ; then
    lxc exec $host -- tc qdisc del dev eth0 root netem
elif [ $1 == "block" ] ; then
    lxc exec $host -- nft -f /etc/nftables.conf
    lxc exec $host -- nft add rule inet filter input tcp dport 11211 drop
elif [ $1 == "unblock" ] ; then
    lxc exec $host -- nft flush table inet filter
elif [ $1 == "reload" ] ; then
    lxc exec mc-proxy -- bash -c 'kill -SIGHUP `cat /tmp/memcached.pid`'
fi
