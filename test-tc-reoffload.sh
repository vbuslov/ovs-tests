#!/bin/bash
#
# This test verifies re-offload functionality when block that already has
# offloaded rules is attached to another qdisc. Expected behavior is that all
# existing rules are re-offloaded to new device and any new rules are offloaded
# to both devices.
#
# Bug SW #1490716: Expose classifiers in_hw_count value to user-space
#

total=${1:-50000}
rules_per_file=10000

my_dir="$(dirname "$0")"
. $my_dir/common.sh
action_type=$1

test -z "$NIC" && fail "Missing NIC"
test -z "$NIC2" && fail "Missing NIC2"
test -z "$REP" && fail "Missing REP"
test -z "$REP2" && fail "Missing REP2"

echo "setup"
num=`cat /sys/class/net/$NIC/device/sriov_numvfs`
if [ "$num" == "0" ]; then
    echo 2 > /sys/class/net/$NIC/device/sriov_numvfs
fi
enable_switchdev_if_no_rep $REP

num=`cat /sys/class/net/$NIC2/device/sriov_numvfs`
if [ "$num" == "0" ]; then
    echo 2 > /sys/class/net/$NIC2/device/sriov_numvfs
fi
enable_switchdev_if_no_rep $REP2

reset_tc_nic $NIC
reset_tc_nic $NIC2
reset_tc_nic $REP
reset_tc_nic $REP2

echo "Clean tc rules"
TC=tc
$TC qdisc del dev $REP ingress > /dev/null 2>&1
$TC qdisc del dev $REP2 ingress > /dev/null 2>&1

OUT="/tmp/test_reoffload"

function check_num_rules() {
    local count=$1
    local itf=$2
    title " - check for $count rules"
    RES="$TC -s filter show dev $itf ingress | grep in_hw"
    RES=`eval $RES | wc -l`
    if (( RES == $count )); then success; else err; fi
}

function check_num_offloaded_rules() {
    local num=$1
    local offload_count=$2
    local block=$3
    title " - check for $num rules"
    RES="$TC -s filter show block 1 ingress | grep 'in_hw in_hw_count $offload_count'"
    RES=`eval $RES | wc -l`
    if (( RES == $num )); then success; else err; fi
}

function tc_batch() {
    local n=0
    local count=0
    local handle=0

    rm -fr $OUT
    mkdir -p $OUT

    for ((i = 0; i < 99; i++)); do
        for ((j = 0; j < 99; j++)); do
            for ((k = 0; k < 99; k++)); do
                for ((l = 0; l < 99; l++)); do
                    SMAC="e4:11:$i:$j:$k:$l"
                    DMAC="e4:12:$i:$j:$k:$l"
                    ((handle+=1))
                    rule="block 1 \
protocol ip \
ingress \
prio 1 \
handle $handle \
flower \
$skip \
src_mac $SMAC \
dst_mac $DMAC \
action drop"
                    echo "filter add $rule" >> ${OUT}/add.$n
                    echo "filter change $rule" >> ${OUT}/ovr.$n
                    echo "filter del $rule" >> ${OUT}/del.$n

                    ((count+=1))
                    let p=count%${rules_per_file}
                    if [ $p == 0 ]; then
                        ((n++))
                    fi
                    if ((count>=total)); then
                        break;
                    fi
                done
                if ((count>=total)); then
                    break;
                fi
            done
            if ((count>=total)); then
                break;
            fi
        done
        if ((count>=total)); then
            break;
        fi
    done
}

function par_test() {
    local del=$1
    local max_rules=$total

    ! $TC qdisc del dev $REP ingress_block 1 ingress
    ! $TC qdisc del dev $REP2 ingress_block 1 ingress
    $TC qdisc add dev $REP ingress_block 1 ingress

    echo "Insert rules"
    $TC -b ${OUT}/add.0 &>/dev/null
    check_num_offloaded_rules $rules_per_file 1 1

    $TC qdisc add dev $REP2 ingress_block 1 ingress &>/dev/null &

    if [ $del == 0 ]; then
        echo "Add rules in parallel"
        ls ${OUT}/add.* | xargs -n 1 -P 100 sudo $TC -b &>/dev/null
        wait
        check_num_offloaded_rules $max_rules 2 1
    else
        echo "Delete rules in parallel"
        ls ${OUT}/del.* | xargs -n 1 -P 100 sudo $TC -b &>/dev/null
        wait
        check_num_offloaded_rules 0 2 1
    fi
}

tc_batch

echo "Test reoffload while overwriting rules"
par_test 0

echo "Test reoffload while deleting rules"
par_test 1

test_done
