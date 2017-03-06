#!/bin/sh
#
# Bug SW #984397: OVS reports failed to put[modify] (No such file or directory)
# Bug SW #988519: Trying to replace a flower rule cause a syndrome and rule to be deleted
#

NIC=${1:-ens5f0}

my_dir="$(dirname "$0")"
. $my_dir/common.sh


LOCAL_IP=99.99.99.5
REMOTE_IP=99.99.99.6
CLEAN="sed -e 's/used:.*, act/used:used, act/;s/eth(src=[a-z0-9:]*,dst=[a-z0-9:]*)/eth(macs)/;s/recirc_id(0),//;s/,ipv4(.*)//' | sort"

port1=ens5f2
port2=ens5f0_0
port3=ens5f3
port4=ens5f0_1

echo "clean netns"
function clean_ns() {
    ip netns del red &> /dev/null
    ip netns del blue &> /dev/null
}
clean_ns

echo "setup netns"
ip netns add red
ip netns add blue
ip link set $port1 netns red
ip link set $port3 netns blue
ip netns exec red ifconfig $port1 $LOCAL_IP/24 up
ip netns exec blue ifconfig $port3 $REMOTE_IP/24 up
ifconfig $port2 up
ifconfig $port4 up

echo "clean ovs"
del_all_bridges
systemctl restart openvswitch
sleep 1
del_all_bridges

echo "prep ovs"
ovs-vsctl add-br br3
ovs-vsctl add-port br3 $port2
ovs-vsctl add-port br3 $port4

# generate rule
ip netns exec red ping -i 0.25 -c 8 $REMOTE_IP

function check_offloaded_rules() {
    title " - check for $1 offloaded rules"
    RES="ovs-dpctl dump-flows type=offloaded | grep 0x0800 | $CLEAN"
    eval $RES
    RES=`eval $RES | wc -l`
    if (( RES == $1 )); then success; else err; fi
}

function check_ovs_rules() {
    title " - check for $1 ovs dp rules"
    RES="ovs-dpctl dump-flows type=ovs | grep 0x0800 | $CLEAN"
    eval $RES
    RES=`eval $RES | wc -l`
    if (( RES == $1 )); then success; else err; fi
}



check_offloaded_rules 2
check_ovs_rules 0

title "change ofctl normal rule to all"
start_check_syndrome
ovs-ofctl del-flows br3
sleep 1
ovs-ofctl add-flow br3 dl_type=0x0800,actions=all
sleep 1
check_offloaded_rules 0
check_ovs_rules 2
check_syndrome && success || err

title "change ofctl all rule to normal"
start_check_syndrome
ovs-ofctl del-flows br3
sleep 1
ovs-ofctl add-flow br3 dl_type=0x0800,actions=normal
sleep 1
check_offloaded_rules 2
check_ovs_rules 0
check_syndrome && success || err

title "change ofctl normal rule to drop"
start_check_syndrome
ovs-ofctl del-flows br3
sleep 1
ovs-ofctl add-flow br3 dl_type=0x0800,actions=drop
sleep 1
check_offloaded_rules 2
check_ovs_rules 0
check_syndrome && success || err

del_all_bridges
clean_ns
echo "done"