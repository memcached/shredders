#!/bin/bash

set -x

TEST="$HOME/test/conf/suite.lua"

NODES="mc-node1 mc-node2 mc-node3"
PNODE="mc-proxy"
ALLNODES="$NODES $PNODE"

MCSBIN="$HOME/test/bin/mcshredder/mcshredder"
MCBIN="$HOME/test/bin/memcached/memcached"

stop_nodes() { 
    for node in $ALLNODES
    do
    echo "Stopping $node"
        lxc stop $node &
    done
    wait
}

start_nodes() { 
    for node in $ALLNODES
    do
    echo "Starting $node"
        lxc start $node &
    done
    wait
}

stop_nodes

start_nodes
# let DNS settle
sleep 1

MCPIP=$(dig +short mc-proxy.lxd)

if [[ $2 ]] then
    ADDARG="--arg $2"
fi

if [ $1 == "run" ] ; then
    echo "Starting mcshredder against $MCPIP"
    $MCSBIN --ip $MCPIP --conf $TEST $ADDARG
elif [ $1 == "prep" ] ; then
    echo $MCSBIN --ip $MCPIP --conf $TEST $ADDARG
elif [ $1 == "memprofile" ] ; then
    $MCSBIN --ip $MCPIP --conf $TEST $ADDARG --memprofile
fi
