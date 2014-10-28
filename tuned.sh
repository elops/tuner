#!/bin/bash -E

# PATH

# defaults
lock_dir_created=0
lock_dir='/tmp/being-tuned'
hypervisor=0
xen=0

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
    hypervisor=1    
  else
    xen=1
  fi
fi

# what block devices present on system
declare -a device_list=($(find /dev/disk/by-id/ ! -name '*-part*' -type l | while read link
  do
    basename $(readlink -f "$link")
  done | sort | uniq))

for device in  "${device_list[@]}"
do
  echo ">> $device"
done


