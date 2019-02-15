#!/usr/bin/env bash
# Time-stamp: <2015-12-11 11:11:19 dky>
#------------------------------------------------------------------------------
# File  : run_hwpmc
# Usage : sudo ./run_hwpmc [iteration_id] [runtime_secs]
# Desc  : Captures the HWPMC (hardware counters) and processes it in gprof
#------------------------------------------------------------------------------
ITERATION=${1:-0}
TIMEOUT=${2:-0}
LOGDIR=${LOGDIR:-/mroot/etc/mlog/hwpmc}

ACTION=${ACTION:-eval}
CPUS=`sysctl hw.ncpu 2>/dev/null|cut -d':' -f2|tr -d ' '`
CPUS=${CPUS:-8}

# Useful counters
PMCEVENTS="-S INSTR_RETIRED_ANY"

# Overwrite from Grover lab
PMCRATE=1000000
PMCEVENTS=${PMCEVENTS:-"-S CPU_CLK_UNHALTED_CORE"}

if [ $TIMEOUT -gt 0 ] ; then
    TIMEOUT="sleep $TIMEOUT"
else
    TIMEOUT=""
    echo "Note: Hit CRTL-C to stop collecting and start processing the logs when done"
fi

# Simple function to handle pipes in commands when echoing
function run()
{
    ${ACTION} $*
}

#------------------------------------------------------------------------------
# Execution starts from here
#------------------------------------------------------------------------------
run "rm -fr ${LOGDIR}/hwpmc_iteration_${ITERATION}/*"
run "mkdir -p ${LOGDIR}/hwpmc_iteration_${ITERATION}"

run "ident /boot/modules/maytag.ko | grep Ntap > ${LOGDIR}/hwpmc_iteration_${ITERATION}/ident_ntap.txt"

run "pmcstat -O ${LOGDIR}/hwpmc_iteration_${ITERATION}/system_sample.out -n ${PMCRATE} ${PMCEVENTS} $TIMEOUT"
echo ""

#------------------------------------------------------------------------------
# Processing the stats
#------------------------------------------------------------------------------
echo "Processing hwpmc gprof flat profiles"
run "pmcstat -R ${LOGDIR}/hwpmc_iteration_${ITERATION}/system_sample.out -k /boot/modules -g -D ${LOGDIR}/hwpmc_iteration_${ITERATION} 2>/dev/null &"

echo "Processing hwpmc data and generating ${LOGDIR}/hwpmc_iteration_${ITERATION}/profile_iteration_all.txt"
run "pmcstat -R ${LOGDIR}/hwpmc_iteration_${ITERATION}/system_sample.out -k /boot/modules -z 8 -G ${LOGDIR}/hwpmc_iteration_${ITERATION}/profile_iteration_all.txt 2>/dev/null &"

# Wait for the background jobs to complete
wait

echo "Processing gprof compatible output to readable text output"
for mod in `\ls -1 /boot/modules/*` ; do
    modf=`basename $mod`
    file=(${LOGDIR}/hwpmc_iteration_${ITERATION}/*/${modf}.gmon)
    if [ ! -e ${file} ] ; then
	continue
    fi

    run "gprof $mod $file > ${LOGDIR}/hwpmc_iteration_${ITERATION}/${modf}.txt"
done

#------------------------------------------------------------------------------
# Archive and compress the gprof data
#------------------------------------------------------------------------------
run "tar -C ${LOGDIR} -zcf ${LOGDIR}/hwpmc_iteration_${ITERATION}.tar.gz hwpmc_iteration_${ITERATION}"

echo "Processing completed for all CPUs: ${LOGDIR}/hwpmc_iteration_${ITERATION}.tar.gz"