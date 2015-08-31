#!/bin/bash
#
# Backup script using rdiff-backup.
#


############################################################
# Settings
############################################################

# Options for duplicity backup.
optDupliBack="--volsize=100 --no-encryption --full-if-older-than 1M"
# Options for duplicity to remove old files.
optDupliClean="remove-all-but-n-full 1 --force"

# Options for rdiff backup.
#optRdiffBackup="–-exclude-sockets --print-statistics"
optRdiffBackup="--print-statistics"
# Options for rdiff to remove old files.
optRdiffClean="--remove-older-than 1M --force"

# Where to put the logfile by default.
#logfile=/var/log/duplibash
logfile=/var/log/backup



############################################################
# Helper functions 
############################################################

function out() {
  while read line; do
    # Add prefix to the output.
    case $1 in
      suc)
        #tmp=`echo -e "INF: \e[34mSUCCESS: $line\e[0m"`
        tmp=`echo "INF: SUCCESS - $line"`
        ;;
      warn)
        tmp=`echo "WAR: $line"`
        ;;
      err)
        #tmp=`echo -e "\e[31mERR: $line\e[0m"`
        tmp=`echo "ERR: $line"`
        ;;
      *)
        tmp=`echo "INF: $line"`
    esac
    
    # Print to stdout  if 
    # - verbose is set.
    # - an error is printed.
    # - a success is printed
    if ( [[ $verbose == "true" ]] || [[ $1 == "err" ]] || [[ $1 == "suc" ]] ); then
      #echo $tmp > /dev/stdout
      echo $tmp
    fi
    
    # Add a time stamp and print to the log file.
    echo $tmp | grep -v "^$" | sed -e "s/^/$(date +"[%Y-%m-%d %H:%M:%S]") /" >> $logfile
  done
}

# Print errors to the log file, to stderr and to stdout.
function exitOnFailure() {
  if [ $1 -ne 0 ]; then
    sleep 2
    echo $2 | out err
    echo "" | out inf
    exit 1
  fi
}

# Print help message.
function usage(){
  #echo "Bash script to run backups with duplicity."
  echo "Bash script to run backups with rdiff-backup."
  echo ""
  echo "Usage:"
  echo "  $0 [options] file"
  echo "  $0 [options] source destination type"
  echo ""
  echo "Options:"
  #echo "  -c    check the given task(s)"
  #echo "  -d    print additional information"
  echo "  -h    show this help"
  echo "  -l    specify log file"
  #echo "  -n    dry run"
  echo "  -v    verbose output"
  echo ""
  #echo "Source code and more information can be found in the github repository."
}



############################################################
# Main
############################################################

#
# Some initial stuff
# 

# Set verbose to false by default.
verbose=false


## Get options ##

while getopts :hl:v opt; do
  case $opt in
    h) # show help
      usage
      exit 0
      ;;
    l) # where to put the log file
      logfile=$OPTARG
      ;;
    v)
      verbose=true
      ;;
    \?) # unrecognized option - show help
      echo "EXIT: Invalid option: -$OPTARG"
      exit 2
      ;;
  esac
done


## Prepare log file ##

# Create log file if it does not exist.
mkdir -p $(dirname logfile)
if [ $? -ne 0 ]; then
  echo "EXIT: Could not create directory for log file."
  exit 1
fi
touch $logfile
if [ $? -ne 0 ]; then
  echo "EXIT: Could not create log file."
  exit 1
fi

# Print log header.
echo "##########################################################################" | out
echo "# Backup, $(date +"%c")" | out
echo "##########################################################################" | out


## Get arguments ##

shift $((OPTIND - 1))

# Check how many arguments are given:
# 0:  show help message and exit
# 1:  assume its a path to the file containing the tasks
# 2+: assume the arguments describe a single tasks
if [ $# -eq 0 ]
then
  usage
  exit 1
elif [ $# -eq 1 ]
then
  tasks=`cat $1 2> /dev/null | egrep -v '(^#|^\s*$|^\s*\t*#)'`
  exitOnFailure $? "file '$1' cannot be read."
else
  tasks=$@
fi



#
# Main loop to evaluate and run each task 
#

echo "" | out

printf '%s\n' "$tasks" | while read task
do
  # Get path to the source and the destination.
  src=$(echo $task | awk '{ print $1 }')
  dest=$(echo $task | awk '{ print $2 }')
  
  # Print info for the current task.
  echo "## Backup $src" | out
  echo "" | out
  
  
  ## Check src and dest ##
  
  # Test for zfs.
  zfs list $src 2> /dev/null > /dev/null
  if [ $? -eq 0 ]; then
    type="zfs"
  fi 
  # Test for lvm.
  if [ -b /dev/$src ] || [ -b $src ]; then
    echo "" | out
    lvs $src 2> /dev/null > /dev/null
    if [ $? -eq 0 ]; then
      type="lvm"
    fi
  fi
  # Test for directory.
  if [ -d $src -a -r $src ]; then
    type="dir"
  fi
  # Exit if src is not a valid type.
  if [ -z "$type" ]; then
    exitOnFailure 1 "$src is not a valid source."
  fi
  
  # Check if dest exists and is writable.
  if [ ! -d $dest ]; then
    exitOnFailure 1 "$dest is not a valid path for the backup."
  fi
  if [ ! -w $dest ]; then
    exitOnFailure 1 "$dest is not writable."
  fi
  pathDest=$dest
  
  
  ## Preparation ##
  
  case "$type" in
    zfs)
      # Get the mount point of the zfs dataset.
      pathSrc=`zfs list $src | grep $src | awk '{ print $5 }'`
      ;;
    lvm)
      # Get the name of the volume group and the logic volume.
      vgName=`lvs $src | tail -n 1 | awk '{ print $2 }'`
      lvName=`lvs $src | tail -n 1 | awk '{ print $1 }'`
      
      # Define the name and the size of the snapshot.
      snapshotName=snap_${lvName}
      snapshotSize=$(lvdisplay -C $src| tail -n+2 | awk '{ print $4 }' )
      
      # Create the snapshot.
      lvcreate --size $snapshotSize --snapshot --name $snapshotName $src 2> >(out warn) 1> >(out inf)
      exitOnFailure $? "Could not greate snapshot."
      
      # Mount the snapshot.
      pathSrc=/mnt/$snapshotName
      mkdir $pathSrc 2> >(out warn) 1> >(out inf)
      exitOnFailure $? "Could not create folder to mount snapshot."
      mount /dev/$vgName/$lvName $pathSrc 2> >(out warn) 1> >(out inf)
      exitOnFailure $? "Could not mount snapshot."
      ;;
    dir)
      # Nothing to do for type 'dir'.
      ;;
  esac
  
  
  ## Backup ##
  
  # Run the backup.
  #duplicity $optDupliBack $pathSrc file://$pathDest 2> >(out warn) 1> >(out inf)
  rdiff-backup $optRdiffBackup $pathSrc $pathDest 2> >(out warn) 1> >(out inf)
  #exitOnFailure $? "Duplicity backup failed."
  exitOnFailure $? "rdiff-backup backup failed."
  
  # Remove old backup files.
  #duplicity $optDupliClean file://$pathDest 2> >(out warn) 1> >(out inf)
  rdiff-backup $optRdiffClean $pathDest 2> >(out warn) 1> >(out inf)
  #exitOnFailure $? "Duplicity remove old files failed."
  exitOnFailure $? "rdiff-backup remove old files failed."
  
  
  ## Clean up ##
  
  case "$type" in
    zfs)
      # Nothing to do for type 'zfs'.
      ;;
    lvm)
      # Unmount the snapshot.
      umount $pathSrc 2> >(out warn) 1> >(out inf)
      exitOnFailure $? "Could not unmount snapshot."
      
      # Delte the mount point.
      rm -rv $pathSrc 2> >(out warn) 1> >(out inf)
      exitOnFailure $? "Could not delete mount folder."
      
      # Remove the snapshot.
      lvremove -f $vgName/$snapshotName 2> >(out warn) 1> >(out inf)
      exitOnFailure $? "Could not remove snapshot."
      ;;
    dir)
      # Nothing to do for type 'dir'.
      ;;
  esac
  
  # Print final message.
  sleep 2
  echo "" | out
  echo "Backup $src." | out suc
  echo "" | out
  
done
