#!/bin/bash 

usage()
{
  echo "Usage: test-playground.sh [options]"
  echo "    -h     Display help"
  echo "    -d     HPCC-Platform source directory path"
  echo "    -s     EclWatch ip or FQDN"
  echo "    -t     targets. Such as 'hthor roxie thor'"
  exit
}

HPCC_HOME=$1
SERVER=
OUT_DIR=log
TARGETS="hthor roxie-workunit thor"
PORT=8010
while getopts “hd:s:t:” opt
do
  case $opt in
    d) HPCC_HOME=$OPTARG ;;
    o) OUT_DIR=$OPTARG ;;
    s) SERVER=$OPTARG ;;
    t) TARGETS=$OPTARG ;;
    h) usage   ;;
  esac
done
shift $(( $OPTIND-1 ))

ERR_DIR=${OUT_DIR}/err

[ -z "$SERVER" ] || [ -z "$HPCC_HOME" ] && usage

ECL_DIR=${HPCC_HOME}/esp/src/eclwatch/ecl

get_timers()
{
  wufile=$1
  start_time_in_ms=$(sed -n '/<Statistic/,/\/>/{
    /<Statistic/ { h; b next }
    /\/>/ { H; x; /kind=\"WhenCreated\".*s=\"global\"/p; b next }
    H
    :next
  }' $wufile | grep "value=" | cut -d'"' -f 2)


  end_time_in_ms=$(sed -n '/<Statistic/,/\/>/{
    /<Statistic/ { h; b next }
    /\/>/ { H; x; /kind=\"WhenFinished\".*s=\"global\"/p; b next }
    H
    :next
  }' $wufile | grep "value=" | cut -d'"' -f 2)

  #echo "start: $start_time_in_ts, end: $end_time_in_ts"
  wu_time="$(echo "scale=3; ($end_time_in_ms - $start_time_in_ms) / (1000000) " | bc)s"

  compile_time_in_ns=$(sed -n '/<Statistic/,/\/>/{
    /<Statistic/ { h; b next }
    /\/>/ { H; x; /kind=\"TimeElapsed\".*s=\"operation\".*scope=\"&gt;compile:&gt;generate\"/p; b next }
    H
    :next
  }' $wufile | grep "value=" | cut -d'"' -f 2)
  compile_time="$(echo "scale=3; ${compile_time_in_ns} / 1000000000" | bc)s"

  wu_execute_time_in_ns=$(sed -n '/<Statistic/,/\/>/{
    /<Statistic/ { h; b next }
    /\/>/ { H; x; /kind=\"TimeElapsed\".*s=\"global\"/p; b next }
    H
    :next
  }' $wufile | grep "value=" | cut -d'"' -f 2)
  wu_execute_time="$(echo "scale=3; ${wu_execute_time_in_ns} / 1000000000" | bc)s"

  #echo "wufile: $wufile"
  cluster_time_in_ns=$(grep "totalThorTime" $wufile | sed "s/.*\([0-9]\+:[0-9]\+:[0-9]\+\.[0-9]\+\).*/\1/")
  #cluster_time=0000
  cluster_time=${cluster_time_in_ns}
  cluster_time=${cluster_time_in_ns#0:*}
  cluster_time=${cluster_time#00:*}
  cluster_time=${cluster_time#00*}
  cluster_time="${cluster_time#0*}"
  [ -n "$cluster_time" ] && cluster_time="${cluster_time}s"
}

mkdir -p $OUT_DIR

total_count=0
total_succeeded=0
total_failed=0
result="OK"
echo "Playground ECL sample Tests"
echo "---------------------------------------------------------"
echo "USER-END: ecl run execution time from user end"
echo "SERVER-END: time difference of 'WhenFinished' and 'WhenCreated' for 's=global' in Statistic section of Wu dump XML"
echo "WU-EXEC: 'TimeElapsed' for 's=global' in Statistic section of Wu dump XML"
echo "COMPILE: 'TimeElapsed' for 's=compile' in Statistic section of Wu dump XML"
echo "CLUSTER:  'totalThorTime' in the WU dump XML header"
for target in $TARGETS
do
  count=0
  succeeded=0
  failed=0
  log_dir=${OUT_DIR}/${target}
  err_dir=${ERR_DIR}/${target}
  mkdir -p $log_dir
  echo 
  echo "$target"
  echo "============"
  printf "%5s %-36s %10s %15s %15s %12s %12s %14s\n" "INDEX" "NAME" "RESULT" "USER-END" "SERVER-END" "WU-EXEC" "COMPILE" "CLUSTER"
  for file in $(ls ${ECL_DIR}) 
  do
    ext=$(echo $file | cut -d'.' -f2)
    [ "$ext" != "ecl" ] && continue
    test_name="$(echo $file | cut -d'.' -f1)"
    count=$(expr $count + 1)
    total_count=$(expr $total_count + 1)
    printf "%5s %-36s" "$count" "$test_name"
    out_file=/tmp/test_playground_time_$$.out
    { time ecl run $target -s $SERVER ${ECL_DIR}/${file} -v  > ${log_dir}/${test_name}.log 2>&1 ; } 2> ${out_file}
    if [ $? -eq 0 ]
    then
       succeeded=$(expr $succeeded \+ 1)
       total_succeeded=$(expr $total_succeeded \+ 1)
       result=OK
    else
       failed=$(expr $failed \+ 1)
       total_failed=$(expr $total_failed \+ 1)
       result=Failed
       mkdir -p ${err_dir}
    fi
    wuid=$(cat ${log_dir}/${test_name}.log | grep wuid: | cut -d':' -f2 | sed -r 's/\s+//g')
    eclplus server=${SERVER}:${PORT} cluster=${target} wuid=${wuid} dump  > ${OUT_DIR}/wu_dump.out
    get_timers ${OUT_DIR}/wu_dump.out
    cp ${OUT_DIR}/wu_dump.out ${log_dir}/${test_name}.wu_dump.xml

    if [ "$result" = "Falied" ]
    then
     cp ${log_dir}/${test_name}.wu_dump.xml ${err_dir}/
     cp ${out_file} ${err_dir}/${test_name}.run.err
    fi


    user_end_time=$(cat $out_file | grep "^real" | awk '{print $2}')
    user_end_time_min=$(echo $user_end_time | cut -d'm' -f1)
    user_end_time_sec=$(echo $user_end_time | cut -d'm' -f2 | cut -d's' -f1)
    user_end_time="$( echo "scale=3; (($user_end_time_min * 60) + $user_end_time_sec)" | bc )s"

    rm -rf $out_file

    printf " %10s %15s %15s %12s %12s %14s\n" "[ $result ]" "[ $user_end_time ]" "[ $wu_time ]" "[ $wu_execute_time ]" "[ $compile_time ]" "[ $cluster_time ]"
  done 
  echo "============"
  echo "Summary ($target):"
  printf "%-15s: %3s\n" "Total tests" "$count"
  printf "%-15s: %3s\n" "Succeeded" "$succeeded"
  printf "%-15s: %3s\n\n" "Failed" "$failed"

done
echo "---------------------------------------------------------"
echo "Summary:"
printf "%-15s: %3s\n" "Total tests" "$total_count"
printf "%-15s: %3s\n" "Succeeded" "$total_succeeded"
printf "%-15s: %3s\n\n" "Failed" "$total_failed"

#eclplus server=http://52.186.35.138:8010 cluster=hthor wuid=W2021030 dump
#eclplus server=http://52.186.35.138:8010 cluster=hthor wuid=W20210302-153944 dump  > ~/tmp/workunit.log
