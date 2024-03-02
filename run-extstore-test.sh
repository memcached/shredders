#!/bin/bash

set -x

TEST="$HOME/test/conf/suite.lua"

ALLNODES="mc-extstore"

MCSBIN="$HOME/test/bin/mcshredder/mcshredder"

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

MCPIP=$(dig +short mc-extstore.lxd)

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
