#!/bin/bash
#
# This verifies that tc API correctly handles several types of request
# to deleted qdisc.

my_dir="$(dirname "$0")"
. $my_dir/common.sh

test -z "$NIC" && fail "Missing NIC"

echo "setup"
reset_tc_nic $NIC

function check_num_rules() {
    local count=$1
    local itf=$2
    title " - check for $count rules"
    RES="tc -s filter show dev $itf ingress | grep in_hw"
    eval $RES
    RES=`eval $RES | wc -l`
    if (( RES == $count )); then success; else err; fi
}

function check_num_actions() {
    local count=$1
    local type=$2
    title " - check for $count actions"
    RES="sudo tc -s actions ls action $type | grep order"
    eval $RES
    RES=`eval $RES | wc -l`
    if (( RES == $count )); then success; else err; fi
}

! tc qdisc del dev $NIC ingress
tc filter add dev $NIC protocol 0x800 ingress prio 10 handle 1 flower skip_hw dst_mac e4:11:22:33:44:50 ip_proto udp dst_port 1 src_port 1 action drop && err || success
check_num_rules 0 $NIC
check_num_actions 0 gact
tc qdisc add dev $NIC ingress

test_done
