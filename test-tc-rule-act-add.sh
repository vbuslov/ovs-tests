#!/bin/bash
#
# This verifies basic tc filter and action functionality. Performs sanity test
# of rule/action reference counting and verifies basic assumptions about tc API
# behavior. (can't delete bound actions, etc.)

my_dir="$(dirname "$0")"
. $my_dir/common.sh
action_type=$1
skip=$2

test -z "$NIC" && fail "Missing NIC"
test -z "$REP" && fail "Missing REP"

echo "setup"
num=`cat /sys/class/net/$NIC/device/sriov_numvfs`
if [ "$num" == "0" ]; then
    echo 2 > /sys/class/net/$NIC/device/sriov_numvfs
fi
enable_switchdev_if_no_rep $REP
reset_tc_nic $NIC
reset_tc_nic $REP

# This array defines action_type->action_text mapping
declare -A actions
actions=( ["bpf"]="action bpf bytecode '1,6 0 0 0,'"
          ["connmark"]="action connmark zone 1"
          ["csum"]="action csum ip4h udp"
          ["gact"]="action gact drop"
          ["ife"]="action ife encode type 0xDEAD allow mark dst 02:15:15:15:15:15"
          ["mirred"]="action mirred egress redirect dev $REP"
          ["nat"]="action nat ingress any 192.168.1.1/24"
          ["pedit"]="action pedit munge ip dport set 10"
          ["police"]="action police rate 1mbit burst 100k"
          ["sample"]="action sample rate 100 group 12"
          ["simple"]="action simple sdata test"
          ["skbedit"]="action skbedit priority 10"
          ["skbmod"]="action skbmod swap mac"
          ["tunnel_key"]="action tunnel_key set src_ip 192.168.1.1 dst_ip 192.168.1.2 id 7"
          ["vlan"]="action vlan pop"
          ["xt"]="action xt -j LOG --log-prefix PONG" )

# This array allows to specify estimator per action type
declare -A action_to_estimator
action_to_estimator=( ["police"]="estimator 1sec 2sec"
                      ["vlan"]="estimator 1sec 2sec"
                      ["bpf"]="estimator 1sec 2sec"
                      ["ife"]="estimator 1sec 2sec" )

function check_num_rules() {
    local count=$1
    local itf=$2
    title " - check for $count rules"
    RES="tc -s filter show dev $itf ingress | grep in_hw"
    RES=`eval $RES | wc -l`
    if (( RES == $count )); then success; else err; fi
}

function check_num_actions() {
    local count=$1
    local type=$2
    title " - check for $count actions"
    RES="sudo tc -s actions ls action $type | grep order"
    RES=`eval $RES | wc -l`
    if (( RES == $count )); then success; else err; fi
}

function eval_cmd() {
    title "$1"
    eval "$2" && success || err
    check_num_rules $3 $NIC
    check_num_actions $4 $5
}

function eval_cmd_err() {
    title "$1"
    eval "$2" && err || success
    check_num_rules $3 $NIC
    check_num_actions $4 $5
}

function add_del_rule() {
    local act="$1"
    local arr=($1)
    local act_type=${arr[1]}
    local estimator=${action_to_estimator[$act_type]}
    local spec="dev $NIC protocol ip"
    local qdisc="ingress prio 10"
    local type="flower"
    local rule="flower $skip dst_mac e4:11:22:33:44:50 ip_proto udp dst_port 1 src_port 1"
    local rule2="flower $skip dst_mac e4:11:22:33:44:70 ip_proto udp dst_port 1 src_port 2"

    #module was not compiled
    modinfo act_$act_type || return 0

     eval_cmd "Add rule with $act_type" "tc filter add $spec $qdisc handle 1 $estimator $rule $act index 1" 1 1 $act_type
    eval_cmd_err "Verify that rule duplicate is rejected" "tc filter add $spec $qdisc handle 1 $rule $act index 1" 1 1 $act_type
    eval_cmd_err "Verify that act duplicate is rejected" "tc actions add $act index 1" 1 1 $act_type
    eval_cmd_err "Verify that act delete is rejected" "tc actions del action $act_type index 1" 1 1 $act_type
    eval_cmd_err "Verify that act delete is rejected again" "tc actions del action $act_type index 1" 1 1 $act_type
    eval_cmd "Verify that rule overwrite is accepted" "tc filter change $spec $qdisc handle 1 $estimator $rule $act index 1" 1 1 $act_type
    eval_cmd "Bind rule to existing action" "tc filter add $spec $qdisc handle 2 $rule2 $act index 1" 2 1 $act_type
    eval_cmd "Verify that only first rule is deleted" "tc filter del $spec $qdisc handle 1 $type" 1 1 $act_type
    eval_cmd "Verify that second rule and action are deleted" "tc filter del $spec $qdisc handle 2 $type" 0 0 $act_type

}

function add_del_act() {
    local act=$1
    local arr=($1)
    local act_type=${arr[1]}

    #module was not compiled
    modinfo act_$act_type || return 0

    tc actions flush action $act_type && success || err

    eval_cmd "Add act $act_type" "tc actions add $act index 1" 0 1 $act_type
    eval_cmd_err "Verify that act duplicate is rejected" "tc actions add $act index 1" 0 1 $act_type
    eval_cmd "Verify that act overwrite is accepted" "tc actions change $act index 1" 0 1 $act_type
    eval_cmd "Verify that act is deleted" "tc actions del action $act_type index 1" 0 0 $act_type

    tc actions flush action $act_type && success || err
}

if [ -z "$action_type" ]
then
    for act in "${actions[@]}"
    do
        add_del_rule "$act"
        add_del_act "$act"
    done
else
    add_del_rule "${actions[$action_type]}"
    add_del_act "${actions[$action_type]}"
fi

test_done
