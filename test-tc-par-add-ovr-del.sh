#!/bin/bash
#
# This verifies that parallel rule insert/delete/change is handled correctly
# by tc. Tests with large amount of rules updated in batch mode to find any
# potential bugs and race conditions.

total=${1:-100000}
skip=$2
rules_per_file=10000

my_dir="$(dirname "$0")"
. $my_dir/common.sh
action_type=$1

test -z "$NIC" && fail "Missing NIC"

echo "setup"
reset_tc_nic $NIC

echo "Clean tc rules"
TC=tc
$TC qdisc del dev $NIC ingress > /dev/null 2>&1

OUT="/tmp/test_par_add_ovr_del"

function check_num_rules() {
    local num=$1
    local itf=$2
    title " - check for $num rules"
    RES="tc -s filter show dev $NIC ingress | grep in_hw"
    RES=`eval $RES | wc -l`
    if (( RES == $num )); then success; else err; fi
}

function tc_batch() {
    local dup=$1
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
                    rule="dev ${NIC} prio 1 handle $handle \
protocol ip \
parent ffff: \
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
                        if [ $dup == 1 ]; then
                            handle=0
                        fi
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
    local dup=$1
    local force=''
    local max_rules=$total
    if [ $dup == 1 ]; then
        max_rules=$rules_per_file
        echo "Generating duplicate batches"
        force='-force'
    else
        echo "Generating distinct batches"
    fi

    tc_batch $dup

    ! $TC qdisc del dev $NIC ingress
    $TC qdisc add dev $NIC ingress

    echo "Insert rules in parallel"
    ls ${OUT}/add.* | xargs -n 1 -P 100 sudo tc $force -b &>/dev/null
    check_num_rules $max_rules $NIC

    echo "Overwrite rules in parallel"
    ls ${OUT}/ovr.* | xargs -n 1 -P 100 sudo tc $force -b &>/dev/null
    check_num_rules $max_rules $NIC

    echo "Delete rules in parallel"
    ls ${OUT}/del.* | xargs -n 1 -P 100 sudo tc $force -b &>/dev/null
    check_num_rules 0 $NIC
}

echo "Test parallel distinct handles"
par_test 0

echo "Test duplicate distinct handles"
par_test 1

test_done
