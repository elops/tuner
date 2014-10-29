#!/bin/bash -E

# PATH to ensure we are not tricked into executing some weird binaries
export PATH=/sbin:/bin:/usr/sbin:/usr/bin

# defaults
low_memory_limit=12582912     # consider systems below or equal to this mem a low mem system
lock_dir_created=0
lock_dir='/tmp/being-tuned'
hypervisor=0
xen=0
debug=0

## Functions
_unlock() {
  # cleanup LOCK only if we created it...
  if [ "$lock_dir_created" -eq 1 ]; then
      rm -rf "$lock_dir"
  fi
}

# custom error handler
_exit() {
  local rc=$?
  trap - EXIT

  if [ ! -z "$@" ];then
    echo "$@" 1>&2
  fi
  _unlock
  kill -SIGPIPE $$      # nail the original shell if we were invoked in subshell
  exit "$rc"
}

_generic_err() {
  local rc=$?
  trap - EXIT
  echo "Error on $1 while running : $BASH_COMMAND" 1>&2
  _unlock
  kill -SIGPIPE $$      #  nail the original shell if we were invoked in subshell
  exit "$rc"
}

sysctl_set() {
  setting="$1"
  value="$2"

  if [ "$(sysctl -n "$setting")" -ne "$value" ]; then
    # set new value
    sysctl -w "$setting=$value"
    # update sysctl.conf if necessary
    if egrep -q "^\s*$setting\ " /etc/sysctl.conf; then
      sed -i.bak -e "s/^\s*$setting.*/# updated to '$value' by site5-tuned.sh script on $(date)\n$setting = $value\n/" /etc/sysctl.conf 
    else
      echo -en "# set to '$value' by site5-tuned.sh script on $(date)\n$setting = $value\n\n" >> /etc/sysctl.conf
    fi
  fi
}

sysfs_set() {
  setting="$1"
  value="$2"
  if [ "$(cat "$setting")" -ne "$value" ]; then
    debug "Setting $setting to $value"
    echo "$value" > "$setting"
  fi
} 

debug() {
  if [ "$debug" -eq 1 ]; then
    echo "$@" 1>&2
  fi
}

## script starts here

# traps
trap _exit HUP PIPE INT QUIT TERM EXIT
trap '_generic_err $LINENO' ERR

# lock dir so we are sure we don't have two instances running at same time
if [ -e "$lock_dir" ]; then
  _exit "Another instance of script detected, exiting..."
elif ! mkdir "$lock_dir"; then
  _exit "Can't create lock dir"
else
  lock_dir_created=1
fi

## detecting what configuration details important to our cause
# how much RAM do we have ? 
total_memory=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)

# Ensure sysfs is mounted 
if ! mount  | grep -q ^'sysfs on /sys'; then
  _exit "Can't find sysfs mounted on /sys. Please fix, aborting"
fi

# is system virtual machine or physical server? 
if [ -e /sys/hypervisor/uuid ]; then
  if egrep -q 00000000-0000-0000-0000-000000000000 /sys/hypervisor/uuid; then
    debug ">> Hypervisor detected"
    hypervisor=1    
  else
    debug ">> Xen guest detected"
    xen=1
  fi
fi

# what block devices present on system
declare -a device_list=($(find /dev/disk/by-id/ ! -name '*-part*' -type l | while read link
  do
    basename $(readlink -f "$link")
  done | sort | uniq))

## Making a change...

## Generic settings
# reduce swap usage; less paging in and paging out will save us some IO
# default : 60
sysctl_set vm.swappiness 10

# be more inclined to *not* moving long lived processes from cpu to cpu 
# which will provide more use of local CPU cache
# default : 500000
sysctl_set kernel.sched_migration_cost 5000000

# The wake-up preemption granularity. Increasing this variable reduces wake-up
# preemption, reducing disturbance of compute bound tasks.
# default : 3000000
sysctl_set kernel.sched_min_granularity_ns 10000000    
# default : 4000000
sysctl_set kernel.sched_wakeup_granularity_ns 15000000
# default : 24000000
sysctl_set kernel.sched_latency_ns 24000000

## changed that depend on system profile
# if <= 12 GB RAM 
#  vm.vfs_cache_pressure = 200       # (don't let SLABS eat little RAM we have)
#  vm.dirty_ratio = 10               # don't allow large writes to grow in mem, flush them earlier and +make sure writeback throttling is activated as early as possible
#  vm.dirty_background_ratio = 3 
#  vm.overcommit_memory = 2          # strict memory accounting; we wont allow memory overuse to avoid memory hogs when under pressure
#  vm.overcommit_ratio = 200         # based on observation this ratio is sane ceil value which can be allowed without experiencing mem hogs

if [ "$total_memory" -le "$low_memory_limit" ]; then
  debug "Detected $total_memory which is based on our config low, applying low mem environment tunables"
  debug " * Setting vfs_cache_pressure to higher value to spare some mem which is sitting unused in slabs"
  sysctl_set vm.vfs_cache_pressure 200
  debug " * Tuning dirty ratios to make better use of writeback throttling and give us more latency during high disk IO"
  sysctl_set vm.dirty_ratio 10
  sysctl_set vm.dirty_background_ratio 3
  debug " * Prevent overcommiting memory; set higher limit and impose strict accounting"
  sysctl_set vm.overcommit_ratio 200
  sysctl_set vm.overcommit_memory 2
fi

# TODO
# Apache limits
# devise how much RAM single process is using
# (total RAM - 2 GB / avg process usage) * 1.1 to allow for some slack room
# ensure requests per sec are below half of what we want to set as limit; else report

# sysfs settings for disk scheduler
for device in  "${device_list[@]}"
do
  debug ">> Tuning $device"
  # Favor reads more than writes and do smaller batches to improve latency
  # increase wait time for writes for latency and read efficiency 
  sysfs_set /sys/block/"$device"/queue/iosched/write_expire 30000
  # we do way more reads than writes; adjust ratio accordingly
  sysfs_set /sys/block/"$device"/queue/iosched/writes_starved 5
  # shorter request batches for latency
  sysfs_set /sys/block/"$device"/queue/nr_requests 32
  # improve read throughput
  sysfs_set /sys/block/"$device"/queue/read_ahead_kb 1024
done
