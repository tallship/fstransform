#!/bin/dash
#
# fstransform - transform a file-system to another file-system type,
#               preserving its contents and without the need for a backup
#
# Copyright (C) 2012 Massimiliano Ghilardi
# 
#     This program is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 3 of the License, or
#     (at your option) any later version.
# 
#     This program is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
# 
#     You should have received a copy of the GNU General Public License
#     along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# fstranform.sh
#
#  Created on: Jan 21, 2012
#      Author: max
#

____='           '
PROG=fstransform
PROG_VERSION=%PACKAGE_VERSION%

BOOT_CMD_which=which

CMDS_bootstrap="which expr id"
CMDS="stat mkfifo blockdev losetup fsck mkfs mount umount mkdir rmdir rm dd sync fsmove fsremap"

# optional commands
CMDS_optional="sleep date"

# commands that are optional or required, depending on --prealloc command-line option
CMDS_prealloc="fsattr"

# commands that may need different variants for source and target file-systems
CMDS_dual="fsck"

# commands not found in environment
CMDS_missing=


# start with a clean environment
ERR=0
DEVICE=
FSTYPE=

# nilfs2 is under test, works as target but as fails as source: gets full with usage = 100%
# ocfs2 and reiserfs4 are under test, got kernel crash testing them
FSTYPES_TESTED="ext2 ext3 ext4 reiserfs jfs xfs"
 
DEVICE_BLOCK_SIZE=
DEVICE_SIZE_IN_BYTES=
DEVICE_SIZE_IN_BLOCKS=
DEVICE_IS_INITIALLY_MOUNTED=
DEVICE_MOUNT_POINT=
DEVICE_FSTYPE=
LOOP_FILE=
LOOP_DEVICE=
LOOP_SIZE_IN_BYTES=
LOOP_MOUNT_POINT=
ZERO_FILE=

OPT_CREATE_ZERO_FILE=no
OPT_ASK_QUESTIONS=yes
OPT_TTY_SHOW_TIME=yes
OPT_PREALLOC=

OPTS_fsattr=
OPTS_fsmove=
OPTS_fsremap=
OPTS_mkfs="-q"
OPTS_fsck_source="-p -f"
OPTS_fsck_target="-p -f"
X_COPY_LOOP_FILE=
X_COPY_DEVICE=

USER_ANSWER=
USER_LOOP_SIZE_IN_BYTES=
USER_FORCE_UNTESTED_FSTYPES=

for cmd in $CMDS_bootstrap $CMDS $CMDS_maybe_required $CMDS_optional; do
  eval "CMD_$cmd="
done
for cmd in $CMDS_dual; do
  eval "CMD_${cmd}_source="
  eval "CMD_${cmd}_target="
done

TMP_DIR="/tmp"
VAR_TMP_DIR="/var/tmp"

FIFO_OUT="$TMP_DIR/fstransform.out.$$"
FIFO_ERR="$TMP_DIR/fstransform.err.$$"

PROG_DIR="$VAR_TMP_DIR/fstransform"
PROG_LOG_FILE="$VAR_TMP_DIR/fstransform/fstransform.log.$$"

# after log_init_file(), file descriptor 5 will be log file ~/.fstransform/fstransform.$$
exec 5>/dev/null

# after log_init_{tty,gui}(), file descriptor 1 will be tty or gui file descriptor


show_usage() {
  echo "Usage: $0 [OPTION]... DEVICE NEW-FILE-SYSTEM-TYPE"
  echo "Transform file system inside DEVICE to NEW-FILE-SYSTEM-TYPE,"
  echo "preserving its contents and without need for backup"
  echo
  echo "Options:"
  echo "  --cmd-CMD-NAME=CMD-PATH       set external command CMD-NAME to use."
  echo "                                    default: autodetect"
  echo "  --force-untested-file-systems also transform untested file systems (DANGEROUS)"
  echo "  --list-source-file-systems    list file systems supported as source and exit"
  echo "  --list-target-file-systems    list file systems supported as target and exit"
  echo "  --loop-file=LOOP-FILE         override loop-file path"
  echo "  --loop-mount-point=PATH       override loop-file mount point"
  echo "  --new-size=SIZE               set new file system length. default: device length"
  echo "  --old-file-system=OLD-TYPE    override current (old) file system type autodetection"
  echo "  --opts-fsmove=OPTS            pass OPTS as additional options to 'fsmove'"
  echo "  --opts-fsremap=OPTS           pass OPTS as additional options to 'fsremap'"
  echo "  --opts-mkfs=OPTS              pass OPTS as options to 'mkfs'. default: '-q'"
  echo "  --opts-fsck-source=OPTS       override 'fsck' options for old file system. default: '-p -f'"
  echo "  --opts-fsck-target=OPTS       override 'fsck' options for new file system. default: '-p -f'"
  echo "  --show-time[=yes|=no]         show current time before each message. default: yes"
  echo "  --prealloc[=yes|no]           use EXPERIMENTAL files preallocation. default: no"
  echo "  --questions=[yes|no|on-error] whether to ask questions interactively. default: on-error"
  echo "  --reversible[=yes|no]         create zero-file, fsremap will do a reversible transformation"
  echo "                                  default: no"
  echo "  --x-OPTION=VALUE        set internal, undocumented option. For maintainers only."
  echo "  --zero-file=ZERO-FILE   override zero-file path"
  echo "  --help                  display this help and exit"
  echo "  --version               output version information and exit"
}

show_version() {
  echo "fstransform (fstransform utilities) $PROG_VERSION"
  echo "Copyright (C) 2011-2012 Massimiliano Ghilardi"
  echo ""
  echo "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>."
  echo "This is free software: you are free to change and redistribute it."
  echo "There is NO WARRANTY, to the extent permitted by law."
}

show_tested_fstypes() {
  for fstype in $FSTYPES_TESTED; do
    echo "$fstype"
  done
}

if test "$#" = 1; then
  case "$1" in
    --help) show_usage; exit 0;;
    --version) show_version; exit 0;;
    --list-source-file-systems) show_tested_fstypes; exit 0;;
    --list-target-file-systems) show_tested_fstypes; exit 0;;
  esac
fi


# parse command line arguments and set USER_CMD_* variables accordingly
parse_args() {
  log_info "parsing command line arguments"
  for arg in "$@"; do
    case "$arg" in
      --cmd-*=* )
        cmd="`\"$CMD_expr\" match \"$arg\" '--cmd-\(.*\)=.*'`"
        user_cmd="`\"$CMD_expr\" match \"$arg\" '--cmd-.*=\(.*\)'`"
        eval "USER_CMD_$cmd='$user_cmd'"
        ;;
      --force-untested-file-systems)
        USER_FORCE_UNTESTED_FSTYPES="yes"
        log_info "forcing trasformation of untested file systems (DANGEROUS). '$arg' bytes specified on command line"
        ;;
      --loop-file=*)
        LOOP_FILE="`\"$CMD_expr\" match \"$arg\" '--loop-file=\(.*\)'`"
        log_info "loop file '$LOOP_FILE' specified on command line"
        ;;
      --loop-mount-point=*)
        LOOP_MOUNT_POINT="`\"$CMD_expr\" match \"$arg\" '--loop-mount-point=\(.*\)'`"
        log_info "loop file mount point '$LOOP_MOUNT_POINT' specified on command line"
        ;;
      --new-size=*)
        USER_LOOP_SIZE_IN_BYTES="`\"$CMD_expr\" match \"$arg\" '--new-size=\(.*\)'`"
        log_info "device new (final) file-system length '$USER_LOOP_SIZE_IN_BYTES' bytes specified on command line"
        ;;
      --old-file-system=*)
        DEVICE_FSTYPE="`\"$CMD_expr\" match \"$arg\" '--old-fstype=\(.*\)'`"
        log_info "device old (initial) file-system type '$DEVICE_FSTYPE' specified on command line"
        ;;
      --opts-fsmove=*)
        OPTS_fsmove="`\"$CMD_expr\" match \"$arg\" '--opts-fsmove=\(.*\)'`"
        log_info "options '$OPTS_fsmove' for fsmove specified on command line"
        ;;
      --opts-fsremap=*)
        OPTS_fsremap="`\"$CMD_expr\" match \"$arg\" '--opts-fsremap=\(.*\)'`"
        log_info "options '$OPTS_fsremap' for fsremap specified on command line"
        ;;
      --opts-mkfs=*)
        OPTS_mkfs="`\"$CMD_expr\" match \"$arg\" '--opts-mkfs=\(.*\)'`"
        log_info "options '$OPTS_mkfs' for mkfs specified on command line"
        ;;
      --opts-fsck-source=*)
        OPTS_fsck_source="`\"$CMD_expr\" match \"$arg\" '--opts-fsck-source=\(.*\)'`"
        log_info "options '$OPTS_fsck_source' for fsck(source file-system) specified on command line"
        ;;
      --opts-fsck-target=*)
        OPTS_fsck_target="`\"$CMD_expr\" match \"$arg\" '--opts-fsck-target=\(.*\)'`"
        log_info "options '$OPTS_FSCK_TARGET_FS' for fsck(target file-system) specified on command line"
        ;;
      --prealloc|--prealloc=*)
        # handled in parse_args_late() below
        ;;
      --questions=yes|--interactive)
        OPT_ASK_QUESTIONS=yes
        log_info "assuming interactive execution, '$arg' specified on command line"
        ;;
      --questions=on-error)
        OPT_ASK_QUESTIONS=on-error
        log_info "assuming interactive execution, '$arg' specified on command line"
        ;;
      --questions=no|--no-questions)
        OPT_ASK_QUESTIONS=no
        log_info "assuming non-interactive execution, '$arg' specified on command line"
        ;;
      --reversible|--reversible=yes)
        OPT_CREATE_ZERO_FILE=yes
        log_info "zero file will be created, '$arg' specified on command line"
        ;;
      --reversible=no)
        OPT_CREATE_ZERO_FILE=no
        log_info "skipping creation of zero file, '$arg' specified on command line"
        ;;
      --show-time|--show-time=yes)
        OPT_TTY_SHOW_TIME=yes
        log_info "showing time-of-day for each message, '$arg' specified on command line"
        ;;
      --show-time=no)
        OPT_TTY_SHOW_TIME=no
        log_info "hiding time-of-day for each message, '$arg' specified on command line"
        ;;
      --x-copy-device=*)
        X_COPY_DEVICE="`\"$CMD_expr\" match \"$arg\" '--x-copy-device=\(.*\)'`"
        log_info "(internal option) device will be copied to '$X_COPY_DEVICE' just before remapping"
        ;;
      --x-copy-loop-file=*)
        X_COPY_LOOP_FILE="`\"$CMD_expr\" match \"$arg\" '--x-copy-loop-file=\(.*\)'`"
        CMDS="$CMDS cmp"
        CMD_cmp=
        log_info "(internal option) loop file will be copied to '$X_COPY_LOOP_FILE'"
        log_info_add "command 'cmp' will be needed to verify it after transformation."
        ;;
      --zero-file=*)
        ZERO_FILE="`\"$CMD_expr\" match \"$arg\" '--zero-file=\(.*\)'`"
        log_info "zero file '$ZERO_FILE' specified on command line"
        ;;
      --*)
        log_warn "ignoring unknown option '$arg'"
        ;;
      *)
        if test "$DEVICE" = ""; then
          DEVICE="$arg"
        elif test "$FSTYPE" = ""; then
          FSTYPE="$arg"
        else
          log_info "ignoring extra argument '$arg'"
        fi
        ;;
    esac
  done
}

parse_args_late() {
  for arg in "$@"; do
    case "$arg" in
      --prealloc=yes-i-want-to-lose-my-data)
        OPT_PREALLOC=yes
        log_warn "trying to enable EXPERIMENTAL files preallocation,"
        log_warn_add "option '$arg' specified on command line."
        log_warn_add "be prepared to LOSE your data!"
        if test "$CMD_sleep" != ""; then
          log_warn_add "continuing in 5 seconds..."
          "$CMD_sleep" 5
        fi
        log_warn_add
        ;;
      --prealloc|--prealloc=yes)
        OPT_PREALLOC=no
        log_warn "preallocation is EXPERIMENTAL and not well tested. if you really want to enable it,"
        log_warn_add "specify '--prealloc=yes-i-want-to-lose-my-data' on command line and be prepared to LOSE your data."
        if test "$CMD_sleep" != ""; then
          log_warn_add "continuing in 5 seconds without preallocation..."
          "$CMD_sleep" 5
        fi
        log_warn_add
        ;;
      --prealloc=no)
        OPT_PREALLOC=no
        log_info "disabling preallocation, '$arg' specified on command line"
        ;;
    esac
  done
}


log_def_file() {
  log_file_timestamp() {
    if test "$CMD_date" != ""; then
      echo -n "`\"$CMD_date\" \"+%Y-%m-%d %H:%M:%S\"` " 1>&5
    fi
  }
  log_file_no_timestamp() {
    if test "$CMD_date" != ""; then
      echo -n "                   " 1>&5
    fi
  }
  log_file_info_4_cmd() {
    log_file_timestamp
    echo "$@" 1>&5
  }
  log_file_info() {
    log_file_timestamp
    echo "$PROG: $@" 1>&5
  }
  log_file_info_add() {
    log_file_no_timestamp
    echo "$____  $@" 1>&5
  }
  log_file_start() {
    log_file_timestamp
    echo -n "$PROG: $@" 1>&5
  }
  log_file_end() {
    log_file_timestamp
    echo "$@" 1>&5
  }
  log_file_warn() {
    log_file_no_timestamp
    echo 1>&5
    log_file_timestamp
    echo "$PROG: WARNING: $@" 1>&5
  }
  log_file_warn_add() {
    log_file_no_timestamp
    echo "$____  $@" 1>&5
  }
  log_file_warn_add_prompt() {
    log_file_no_timestamp
    echo "$____  $@" 1>&5
  }
  log_file_err() {
    log_file_no_timestamp
    echo 1>&5
    log_file_timestamp
    echo "ERROR! $PROG: $@" 1>&5  
  }
  log_file_err_add() {
    log_file_no_timestamp
    echo "       $@" 1>&5  
  }
  log_file_err_add_prompt() {
    log_file_no_timestamp
    echo "       $@" 1>&5  
  }
}

log_init_file() {
  "$CMD_mkdir" -p "$PROG_DIR" >/dev/null 2>&1
  > "$PROG_LOG_FILE" >/dev/null 2>&1
  
  if test -w "$PROG_LOG_FILE"; then
    exec 5>"$PROG_LOG_FILE"
  fi
}

log_def_tty() {
  read_user_answer() {
    if test "$OPT_ASK_QUESTIONS" = "no"; then
      USER_ANSWER=
    else
      read USER_ANSWER
    fi
  }

  log_tty_timestamp() {
    if test "$OPT_TTY_SHOW_TIME" = "yes" -a "$CMD_date" != ""; then
      echo -n "`\"$CMD_date\" \"+%H:%M:%S\"` "
    fi
  }
  log_tty_no_timestamp() {
    if test "$OPT_TTY_SHOW_TIME" = "yes" -a "$CMD_date" != ""; then
      echo -n "         "
    fi
  }
  log_info_4_cmd() {
    log_tty_timestamp
    echo "$@"
    log_file_info_4_cmd "$@"
  }
  log_info() {
    log_tty_timestamp
    echo "$PROG: $@"
    log_file_info "$@"
  }
  log_info_add() {
    log_tty_no_timestamp
    echo "$____  $@"
    log_file_info_add "$@"
  }
  log_start() {
    log_tty_timestamp
    echo -n "$PROG: $@"
    log_file_start "$@"
  }
  log_end() {
    echo "$@"
    log_file_end "$@"
  }
  log_warn() {
    log_tty_no_timestamp
    echo
    log_tty_timestamp
    echo "$PROG: WARNING: $@"
    log_file_warn "$@"
  }
  log_warn_add() {
    log_tty_no_timestamp
    echo "$____  $@"
    log_file_warn_add "$@"
  }
  log_warn_add_prompt() {
    log_tty_no_timestamp
    echo -n "$____  $@"
    log_file_warn_add_prompt "$@"
  }
  log_err() {
    log_tty_no_timestamp
    echo
    log_tty_timestamp
    echo "ERROR! $PROG: $@"
    log_file_err "$@"
  }
  log_err_add() {
    log_tty_no_timestamp
    echo "       $@"
    log_file_err_add "$@"
  }
  log_err_add_prompt() {
    log_tty_no_timestamp
    echo -n "       $@"
    log_file_err_add_prompt "$@"
  }
}
log_init_tty() {
  log_quit() {
    # tty implementation of log_quit(): nothing to do
    return 0
  }
  return 0
}

log_quit() {
  # default implementation of log_quit(): nothing to do
  return 0
}

log_def_file
log_init_tty && log_def_tty

ERR="$?"
if test "$ERR" != 0; then
  echo "failed to initialize output to tty!"
  echo "exiting."
  exit "$ERR"
fi

log_info "starting version $PROG_VERSION, checking environment"

detect_cmd() {
  local my_cmd_which="$CMD_which"
  if test "$my_cmd_which" = ""; then
    my_cmd_which="$BOOT_CMD_which"
  fi

  local cmd="$1"
  local my_cmd=
  local user_cmd="`eval echo '$USER_CMD_'\"$cmd\"`"
  
  log_start "checking for $cmd...         "
  
  if test "$user_cmd" != ""; then
    my_cmd="`$my_cmd_which \"$user_cmd\"`" >/dev/null 2>&1
    if test "$my_cmd" != ""; then
      if test -x "$my_cmd"; then
        log_end "'$my_cmd' ('$user_cmd' was specified)"
        eval "CMD_$cmd='$my_cmd'"
        return 0
      fi
    fi
  fi

  my_cmd="`$my_cmd_which \"$cmd\"`" >/dev/null 2>&1
  if test "$my_cmd" != ""; then
    if test -x "$my_cmd"; then
      log_end "'$my_cmd'"
      eval "CMD_$cmd='$my_cmd'"
      return 0
   else
      log_end "found '$my_cmd', but is NOT executable by you!"
    fi
  else
    log_end "NOT FOUND!"
  fi
  CMDS_missing="$CMDS_missing '$cmd'"
  return 1
}

detect_cmd_dual() {
  local my_cmd_which="$CMD_which"
  if test "$my_cmd_which" = ""; then
    my_cmd_which="$BOOT_CMD_which"
  fi
  
  local cmd="$1"
  local source_or_target="$2"
  
  local user_cmd="`eval echo '$USER_CMD_'\"$cmd\"'_'\"$source_or_target\"`"
  local my_cmd=
  log_start "checking for ${cmd}($source_or_target file-system)...        "

  if test "$user_cmd" != ""; then
    my_cmd="`$my_cmd_which \"$user_cmd\"`" >/dev/null 2>&1
    if test "$my_cmd" != ""; then
      if test -x "$my_cmd"; then
        log_end "'$my_cmd' ('$user_cmd' was specified)"
        eval "CMD_${cmd}_$source_or_target='$my_cmd'"
        return 0
      fi
    fi
  fi
  local nondual_cmd="`eval echo '$CMD_'\"$cmd\"`"
  log_end "'$nondual_cmd'"
  eval "CMD_${cmd}_$source_or_target='$nondual_cmd'"
  return 0
}


fix_for_fstype_ntfs() {
  if test "$DEVICE_FSTYPE" = "ntfs-3g"; then
    DEVICE_FSTYPE="ntfs"
  fi
  if test "$FSTYPE" = "ntfs-3g"; then
    FSTYPE="ntfs"
  fi
  local my_cmd_ntfsresize=
  if test "$FSTYPE" = "ntfs" -o "$DEVICE_FSTYPE" = "ntfs"; then
    log_info "applying special options for file-system type 'ntfs'"
    # we need 'ntfsresize', check if it's available
    my_cmd_ntfsresize="`$CMD_which ntfsresize`"
    if test "$my_cmd_ntfsresize" = ""; then
      log_warn "command 'ntfsresize' not found, it is needed to check integrity of file-system type 'ntfs'"
    fi
  fi
  
  if test "$DEVICE_FSTYPE" = "ntfs"; then
    if test "$my_cmd_ntfsresize" != "" -a "$USER_CMD_fsck_source" = ""; then
      USER_CMD_fsck_source="ntfsresize"
      OPTS_fsck_source="-n"
      detect_cmd_dual "fsck" "source"
    fi
  fi
  if test "$FSTYPE" = "ntfs"; then
    if test "$my_cmd_ntfsresize" != "" -a "$USER_CMD_fsck_target" = ""; then
      USER_CMD_fsck_target="ntfsresize"
      OPTS_fsck_target="-n"
      detect_cmd_dual "fsck" "target"
    fi
    # 'mkfs -t nfs' needs option '-f' (quick format) to maintain sparse files
    OPTS_mkfs="$OPTS_mkfs -f"
  fi
}

fix_for_fstype_nilfs2() {
  if test "$DEVICE_FSTYPE" = "nilfs2" -a "$USER_CMD_fsck_target" = ""; then
    # fsck.nilfs2 does not exist.
    # use ':', the standard 'do nothing successfully' command. no need to rely on /bin/true
    USER_CMD_fsck_source=":"
  fi
  if test "$FSTYPE" = "nilfs2" -a "$USER_CMD_fsck_target" = ""; then
    # fsck.nilfs2 does not exist.
    # use ':', the standard 'do nothing successfully' command. no need to rely on /bin/true
    USER_CMD_fsck_target=":"
  fi
}

# apply fixes for special cases...
fix_for_special_cases() {
  fix_for_fstype_nilfs2
  fix_for_fstype_ntfs
}

fail_missing_cmds() {
  log_err "environment check failed."
  log_err_add "Please install the commands$CMDS_missing before running $PROG"
  log_err_add "If these commands are already installed, add them to your \$PATH"
  log_err_add "or tell their location with the option --cmd-COMMAND=/path/to/your/command"
  exit "$ERR"
}





# bootstrap command detection (command 'which') and argument parsing (command 'expr')
for cmd in $CMDS_bootstrap; do
  detect_cmd "$cmd" || ERR="$?"
done
if test "$ERR" != 0; then
  fail_missing_cmds
fi

check_uid_0() {
  local my_uid="`$CMD_id -u`"
  if test "$my_uid" != 0; then
    log_err "this script must be executed as root (uid 0)"
    log_err_add "instead it is currently running as uid $my_uid"
    exit 1
  fi
}
check_uid_0


parse_args "$@"

for cmd in $CMDS; do
  detect_cmd "$cmd" || ERR="$?"
done

for cmd in $CMDS_dual; do
  detect_cmd_dual "$cmd" "source" || ERR="$?"
  detect_cmd_dual "$cmd" "target" || ERR="$?"
done

log_info "looking for optional commands"
for cmd in $CMDS_optional; do
  detect_cmd "$cmd"
done

parse_args_late "$@"

if test "$OPT_PREALLOC" = yes; then
  CMDS="$CMDS $CMDS_prealloc"
  
  for cmd in $CMDS_prealloc; do
    detect_cmd "$cmd" || ERR="$?"
  done
fi


fix_for_special_cases

if test "$ERR" != 0; then
  fail_missing_cmds
fi

log_info "environment check passed."

ERR=0

check_command_line_args() {
  local my_missing=
  if test "$DEVICE" != "" -a "$FSTYPE" != ""; then
    return 0
  elif test "$DEVICE" != ""; then
    my_missing="argument FSTYPE"
  elif test "$FSTYPE" != ""; then
    my_missing="argument DEVICE"
  else
    my_missing="arguments DEVICE and FSTYPE"
  fi
  log_err "missing command-line $my_missing."
  log_err "Try '$0 --help' for more information"
  exit 1
}
check_command_line_args


# inform if a command failed, and offer to fix manually
exec_cmd_status() {
  if test "$ERR" != 0; then
    log_err "command '$@' failed (exit status $ERR)"
    log_err_add "this is potentially a problem."
    if test "$OPT_ASK_QUESTIONS" = "no"; then
      log_err_add
      log_err_add "you could try fix the problem yourself and continue"
      log_err_add "but this is a non-interactive run, so $PROG will exit now"
    else
      log_err_add "you can either quit now by pressing ENTER or CTRL+C,"
      log_err_add
      log_err_add "or, if you know what went wrong, you can fix it yourself,"
      log_err_add "then manually run the command '$@'"
      log_err_add "(or something equivalent)"
      log_err_add_prompt "and finally resume this script by typing CONTINUE and pressing ENTER: "
    fi
    read_user_answer
    if test "$USER_ANSWER" != "CONTINUE"; then
      log_info 'exiting.'
      exit "$ERR"
    fi
    ERR=0
  fi
}

# treat 'fsck' programs specially:
# they exit with status 1 to indicate that file-system errors were corrected
exec_cmd_status_fsck() {
  if test "$ERR" = 1; then
    log_info "command '$@' returned exit status 1"
    log_info_add "this means some file-system problems were found and corrected"
    log_info_add "on ext2, ext3 and ext4 it may simply mean harmless directory optimization"
    log_info_add "continuing..."
    ERR=0
  else
    exec_cmd_status "$@"
  fi
}


remove_fifo_out_err() {
  "$CMD_rm" -f "$FIFO_OUT" "$FIFO_ERR"
}

create_fifo_out_err() {
  remove_fifo_out_err
  "$CMD_mkfifo" -m 600 "$FIFO_OUT" "$FIFO_ERR"
  ERR="$?"
  exec_cmd_status "$CMD_mkfifo" -m 600 "$FIFO_OUT" "$FIFO_ERR"
}
create_fifo_out_err

CLEANUP_SIGNALS="HUP INT QUIT ILL TRAP ABRT BUS FPE KILL SEGV PIPE TERM URG XCPU XFSZ VTALRM PROF IO PWR SYS"
CLEANUP_0=
CLEANUP_1=
CLEANUP_2=
CLEANUP_3=
CLEANUP_4=
CLEANUP_5=

do_cleanup() {
  trap - 0 $CLEANUP_SIGNALS
  
  if test "$CLEANUP_5" != ""; then
    eval "$CLEANUP_5" >/dev/null 2>/dev/null
  fi
  if test "$CLEANUP_4" != ""; then
    eval "$CLEANUP_4" >/dev/null 2>/dev/null
  fi
  if test "$CLEANUP_3" != ""; then
    eval "$CLEANUP_3" >/dev/null 2>/dev/null
  fi
  if test "$CLEANUP_2" != ""; then
    eval "$CLEANUP_2" >/dev/null 2>/dev/null
  fi
  if test "$CLEANUP_1" != ""; then
    eval "$CLEANUP_1" >/dev/null 2>/dev/null
  fi
  if test "$CLEANUP_0" != ""; then
    eval "$CLEANUP_0" >/dev/null 2>/dev/null
  fi
  remove_fifo_out_err
  log_quit
}
cleanup_on_exit() {
  do_cleanup
  log_quit
}
cleanup_on_signal() {
  do_cleanup
  exit 1
}
trap cleanup_on_exit 0
trap cleanup_on_signal $CLEANUP_SIGNALS




log_init_file
log_info "saving output of this execution into $PROG_LOG_FILE"







read_cmd_out_err() {
  local my_cmd_full="$1"
  local my_cmd="`\"$CMD_expr\" match \"$1\" '.*/\([^/]*\)'`"
  if test "$my_cmd" = ""; then
    my_cmd="$my_cmd_full"
  fi
  local my_fifo="$2"
  local my_prefix="$3"
  local my_out_1= my_out=
  while read my_out_1 my_out; do
    if test "$my_out_1" = "$my_cmd:"; then
      log_info_4_cmd "$my_prefix$my_cmd: $my_out"
    elif test "$my_out_1" = "$my_cmd_full:"; then
      log_info_4_cmd "$my_prefix$my_cmd: $my_out"
    else
      log_info_4_cmd "$my_prefix$my_cmd: $my_out_1 $my_out"
    fi
  done < "$my_fifo" &
}

read_cmd_out() {
  read_cmd_out_err "$1" "$FIFO_OUT" ""
}

read_cmd_err() {
  read_cmd_out_err "$1" "$FIFO_ERR" "warn: "
}

exec_cmd_noquit() {
  read_cmd_out "$1"
  "$@" >"$FIFO_OUT" 2>"$FIFO_OUT"
  ERR="$?"
  wait
}

exec_cmd() {
  exec_cmd_noquit "$@"
  exec_cmd_status "$@"
}

# treat 'fsck' programs specially:
# they exit with status 1 to indicate that file-system errors were corrected
exec_cmd_fsck() {
  exec_cmd_noquit "$@"
  exec_cmd_status_fsck "$@"
}

capture_cmd() {
  local my_ret my_var="$1"
  shift
  read_cmd_out "$1"
  my_ret="`\"$@\" 2>\"$FIFO_OUT\"`"
  ERR="$?"
  wait
  if test "$ERR" != 0; then
    log_err "command '$@' failed (exit status $ERR)"
    exit "$ERR"
  elif test "$my_ret" = ""; then
    log_err "command '$@' failed (no output)"
    exit 1
  fi
  eval "$my_var='$my_ret'"
}


check_device_is_block_special() {
  if test ! -b "$DEVICE"; then
    log_err "argument '$DEVICE' is NOT a block special device! Aborting."
    exit 1
  fi
}
check_device_is_block_special


log_info "preparing to transform device '$DEVICE' to file-system type '$FSTYPE'"


echo_device_mount_point_and_fstype() {
  local my_dev="$1"
  "$CMD_mount" | while read dev _on_ mount_point _type_ fstype opts; do
    if test "$dev" = "$my_dev"; then
      echo "$mount_point $fstype"
      break
    fi
  done
}

initial_mount_device() {
  DEVICE_MOUNT_POINT="$TMP_DIR/fstransform.mount.$$"
  "$CMD_mkdir" -p "$DEVICE_MOUNT_POINT" >/dev/null 2>&1
  
  CLEANUP_0="'$CMD_rmdir' '$DEVICE_MOUNT_POINT'"
  
  if test "$DEVICE_FSTYPE" != ""; then
    exec_cmd "$CMD_mount" -t "$DEVICE_FSTYPE" "$DEVICE" "$DEVICE_MOUNT_POINT"
  else
    exec_cmd "$CMD_mount" "$DEVICE" "$DEVICE_MOUNT_POINT"
  fi
  CLEANUP_0="'$CMD_umount' '$DEVICE'; $CLEANUP_0"
}

find_device_mount_point_and_fstype() {
  local my_dev="$DEVICE"
  local my_mount_point= my_fstype= my_now=
  local ret="`echo_device_mount_point_and_fstype \"$my_dev\"`"
  if test "$ret" = ""; then
    log_info "device '$my_dev' not found in the output of command $CMD_mount, assuming it is not mounted"
    initial_mount_device
    local ret="`echo_device_mount_point_and_fstype \"$my_dev\"`"
    if test "$ret" = ""; then
      log_err "just mounted device '$my_dev' at mount point '$DEVICE_MOUNT_POINT'"
      log_err_add "but still cannot find it in the output of command $CMD_mount"
      log_err_add "I give up, sorry"
      exit 1
    fi
    my_now=" now"
  else
    DEVICE_IS_INITIALLY_MOUNTED=yes
  fi
  for i in $ret; do
    if test "$my_mount_point" = ""; then
      my_mount_point="$i"
    else
      my_fstype="$i"
    fi
  done
  log_info "device is$my_now mounted at '$my_mount_point' with file-system type '$my_fstype'"
  if test ! -e "$my_mount_point"; then
    log_err "mount point '$my_mount_point' does not exist."
    log_err_add "maybe device '$my_dev' is mounted on a path containing spaces?"
    log_err_add "$PROG does not support mount points containing spaces in their path"
    exit 1
  fi
  if test ! -d "$my_mount_point"; then
    log_err "mount point '$my_mount_point' is not a directory"
    exit 1
  fi
  DEVICE_MOUNT_POINT="$my_mount_point"
  if test "$my_fstype" = fuseblk; then
    if test "$DEVICE_FSTYPE" != ""; then
      log_info "file-system type '$my_fstype' is a placeholder name for FUSE... ignoring it (user specified type '$DEVICE_FSTYPE')"
    else
      log_info "file-system type '$my_fstype' is a placeholder name for FUSE... ignoring it"
    fi
  elif test "$DEVICE_FSTYPE" != ""; then
    # let's compare user-specified file-system type with what we found...
    # still we honour what the user said.
    if test "$DEVICE_FSTYPE" != "$my_fstype"; then
      log_warn "does not match user-specified device file-system type '$DEVICE_FSTYPE'. using user-specified value."
    fi
  else
    DEVICE_FSTYPE="$my_fstype"
  fi
}
find_device_mount_point_and_fstype



check_for_tested_fstypes() {
  if test "$FSTYPE" = ""; then
    log_err "target file system type not specified!"
    exit 1
  fi
  local my_fstype_source_ok=no my_fstype_target_ok=no
  for my_fstype in $FSTYPES_TESTED; do
    if test "$DEVICE_FSTYPE" = "$my_fstype"; then
      my_fstype_source_ok=yes
      break
    fi
  done
  for my_fstype in $FSTYPES_TESTED; do
    if test "$FSTYPE" = "$my_fstype"; then
      my_fstype_target_ok=yes
      break
    fi
  done
  if test "$my_fstype_source_ok" = "yes" -a "$my_fstype_target_ok" = "yes"; then
    return 0
  fi
  
  local my_log=log_err my_log_add=log_err_add
  if test "$USER_FORCE_UNTESTED_FSTYPES" = "yes"; then
    my_log=log_warn
    my_log_add=log_warn_add
  fi
  if test "$my_fstype_source_ok" != "yes"; then
    if test "$DEVICE_FSTYPE" = ""; then
      "$my_log" "failed to detect device current file system type"
    else
      "$my_log" "this program is UNTESTED on device current file system '$DEVICE_FSTYPE' !"
    fi
  fi
  if test "$my_fstype_target_ok" != "yes"; then
    "$my_log" "this program is UNTESTED on target file system '$FSTYPE' !"
  fi
  "$my_log_add" "this program is tested ONLY on file systems: $FSTYPES_TESTED"
  
  if test "$USER_FORCE_UNTESTED_FSTYPES" = "yes"; then
    "$my_log_add" "continuing anyway due to option '--force-untested-file-systems' (DANGEROUS)"
    return 0
  else
    "$my_log_add" "cowardly refusing to run. if you know what you are doing, you can use"
    "$my_log_add" "option '--force-untested-file-systems' (DANGEROUS, you can LOSE your DATA)"
    exit 1
  fi
}
check_for_tested_fstypes


check_for_prealloc() {
  if test "$OPT_PREALLOC" = "yes"; then
    if test "$FSTYPE" = "ext4"; then
      # detect if we can use preallocation
      if test "$CMD_fsattr" != ""; then
        if "$CMD_fsattr" --help >/dev/null 2>&1; then
          log_info "enabling EXPERIMENTAL files preallocation: target FSTYPE is '$FSTYPE' and command 'fsattr' is available"
          OPT_PREALLOC=yes
        else
          log_warn "cannot enable EXPERIMENTAL files preallocation: target FSTYPE is '$FSTYPE' but command 'fsattr' is a stub"
          OPT_PREALLOC=no
        fi
      else
        log_warn "cannot enable EXPERIMENTAL files preallocation: target FSTYPE is '$FSTYPE' but command 'fsattr' is not available"
        OPT_PREALLOC=no
      fi
    else
      log_warn "cannot enable EXPERIMENTAL files preallocation: currently supported only 'ext4' target, not '$FSTYPE'"
      OPT_PREALLOC=no
    fi
  fi
}
check_for_prealloc


find_device_size() {
  capture_cmd DEVICE_SIZE_IN_BYTES "$CMD_blockdev" --getsize64 "$DEVICE"
  log_info "device raw size = $DEVICE_SIZE_IN_BYTES bytes"
}
find_device_size

create_loop_or_zero_file() {
  local my_kind="$1" my_var="$2" my_file="$3"
  local my_pattern="$DEVICE_MOUNT_POINT/.fstransform.$my_kind.*"
  local my_files="`echo $my_pattern`"
  if test "$my_files" != "$my_pattern"; then
    log_warn "possibly stale $PROG $my_kind files found inside device '$DEVICE',"
    log_warn_add "maybe they can be removed? list of files found:"
    log_warn_add
    log_warn_add "$my_files"
    log_warn_add
  fi
  if test "$my_file" = ""; then
    my_file="$DEVICE_MOUNT_POINT/.fstransform.$my_kind.$$"
    log_info "creating sparse $my_kind file '$my_file' inside device '$DEVICE'..."
    if test -e "$my_file"; then
      log_err "$my_kind file '$my_file' already exists! please remove it"
      exit 1
    fi
  else
    # check that user-specified file is actually inside DEVICE_MOUNT_POINT
    "$CMD_expr" match "$my_file" "$DEVICE_MOUNT_POINT/.*" >/dev/null 2>/dev/null || ERR="$?"
    if test "$ERR" != 0; then
      log_err "user-specified $my_kind file '$my_file' does not seem to be inside device mount point '$DEVICE_MOUNT_POINT'"
      log_err_add "please use a $my_kind file path that starts with '$DEVICE_MOUNT_POINT/'"
      exit "$ERR"
    fi
    "$CMD_expr" match "$my_file" '.*/\.\./.*' >/dev/null 2>/dev/null
    if test "$?" = 0; then
      log_err "user-specified $my_kind file '$my_var' contains '/../' in path"
      log_err_add "maybe somebody is trying to break $PROG?"
      log_err_add "I give up, sorry"
      exit "$ERR"
    fi
    log_info "overwriting $my_kind file '$my_file' inside device '$DEVICE'..."
  fi
  
  exec_cmd_noquit "$CMD_dd" "if=/dev/zero" "of=$my_file" bs=1 count=1
  if test "$ERR" != 0; then
    log_err "failed to create or truncate '$my_file' to zero bytes"
    log_err_add "maybe device '$DEVICE' is full or mounted read-only?"
    exit "$ERR"
  fi
  eval "$my_var='$my_file'"
}

create_loop_file() {
  create_loop_or_zero_file loop LOOP_FILE "$LOOP_FILE"
  
  CLEANUP_1="'$CMD_rm' -f '$LOOP_FILE'"

  # loop file length is = device size truncated down to a multiple of its block size:
  # avoids annoying problems if device's last block has an odd length
  
  capture_cmd DEVICE_BLOCK_SIZE "$CMD_stat" -c %o "$LOOP_FILE"
  log_info "device file-system block size = $DEVICE_BLOCK_SIZE bytes"
  if test "$DEVICE_BLOCK_SIZE" = "" -o "$DEVICE_BLOCK_SIZE" -lt 512; then
    # paranoia...
    DEVICE_BLOCK_SIZE=512
  fi
  : $(( DEVICE_SIZE_IN_BLOCKS = DEVICE_SIZE_IN_BYTES / DEVICE_BLOCK_SIZE ))
  : $(( LOOP_SIZE_IN_BYTES = DEVICE_SIZE_IN_BLOCKS * DEVICE_BLOCK_SIZE ))
  log_info "device usable size = $LOOP_SIZE_IN_BYTES bytes"
  
  if test "$USER_LOOP_SIZE_IN_BYTES" != ""; then
    # only accept user-specified new-size if smaller than maximum allowed,
    # and in any case truncate it down to a multiple of device block size
    if test "$USER_LOOP_SIZE_IN_BYTES" -lt "$LOOP_SIZE_IN_BYTES"; then
      : $(( LOOP_SIZE_IN_BYTES = USER_LOOP_SIZE_IN_BYTES / DEVICE_BLOCK_SIZE * DEVICE_BLOCK_SIZE ))
    fi
    log_info "sparse loop file will be $LOOP_SIZE_IN_BYTES bytes long (user specified $USER_LOOP_SIZE_IN_BYTES bytes)"
  fi
  exec_cmd "$CMD_dd" if=/dev/zero of="$LOOP_FILE" bs=1 count=1 seek="$(( LOOP_SIZE_IN_BYTES - 1 ))"
}
create_loop_file


remount_device_ro() {
  log_info "remounting device '$DEVICE' read-only"
  exec_cmd "$CMD_mount" "$DEVICE" -o remount,ro
}

remount_device_rw() {
  log_info "remounting device '$DEVICE' read-write"
  exec_cmd "$CMD_mount" "$DEVICE" -o remount,rw
}

# detect unsupported corner cases, for example:
# 1) source file systems without FIEMAP support and too large for FIBMAP
# 2) other inconsistencies (which?)
early_remap_validate() {
  log_info "launching '$CMD_fsremap' in simulated mode for pre-validation"

  exec_cmd "$CMD_fsremap" -q $my_OPTS_fsremap -n -- "$DEVICE" "$LOOP_FILE"
}

remount_device_ro
early_remap_validate
remount_device_rw


connect_loop_device() {
  capture_cmd LOOP_DEVICE "$CMD_losetup" -f
  exec_cmd "$CMD_losetup" "$@" "$LOOP_DEVICE" "$LOOP_FILE"
  log_info "connected loop device '$LOOP_DEVICE' to file '$LOOP_FILE'"
  
  CLEANUP_2="'$CMD_losetup' -d '$LOOP_DEVICE'"
}
connect_loop_device

disconnect_loop_device() {
  local my_iter=0
  # loop device sometimes needs a little time to become free...
  for my_iter in 1 2 3 4; do
    exec_cmd "$CMD_sync"
    if test "$my_iter" != 1 -a "$CMD_sleep" != ""; then
      "$CMD_sleep" 5
      exec_cmd "$CMD_sync"
    fi
    if test "$my_iter" != 4; then
      "$CMD_losetup" -d "$LOOP_DEVICE" && break
    else
      exec_cmd "$CMD_losetup" -d "$LOOP_DEVICE"
    fi
  done
  log_info "disconnected loop device '$LOOP_DEVICE' from file '$LOOP_FILE'"

  CLEANUP_2=
}


format_loop_device() {
  log_info "formatting loop device '$LOOP_DEVICE' with file-system type '$FSTYPE'..."
  exec_cmd "$CMD_mkfs" -t "$FSTYPE" $OPTS_mkfs "$LOOP_DEVICE"
}
format_loop_device


mount_loop_file() {
  if test "$LOOP_MOUNT_POINT" = ""; then
    LOOP_MOUNT_POINT="$TMP_DIR/fstransform.loop.$$"
    exec_cmd "$CMD_mkdir" "$LOOP_MOUNT_POINT"
  else
    "$CMD_expr" match "$LOOP_MOUNT_POINT" "/.*" >/dev/null 2>/dev/null
    ERR="$?"
    if test "$ERR" != 0; then
      log_warn "user-specified loop file mount point '$LOOP_MOUNT_POINT' should start with '/'"
      log_warn_add "i.e. it should be an absolute path."
      log_warn_add "$PROG cannot ensure that '$LOOP_MOUNT_POINT' is outside '$DEVICE_MOUNT_POINT'"
      if test "$OPT_ASK_QUESTIONS" = "no"; then
        log_err_add "you could examine the previous warning and decide to continue at your own risk"
        log_err_add "but this is a non-interactive run, so $PROG will exit now"
        log_info "exiting."
        exit "$ERR"
      else
        log_warn_add "continue at your own risk"
        log_warn_add
        log_warn_add_prompt "press ENTER to continue, or CTRL+C to quit: "
        read_user_answer
      fi
    else
      "$CMD_expr" match "$LOOP_MOUNT_POINT" "$DEVICE_MOUNT_POINT/.*" >/dev/null 2>/dev/null
      if test "$?" = 0; then
        log_err "user-specified loop file mount point '$LOOP_MOUNT_POINT' seems to be inside '$DEVICE_MOUNT_POINT'"
        log_err_add "maybe somebody is trying to break $PROG and lose data?"
        log_err_add "I give up, sorry"
        exit 1
      fi
    fi
  fi
  log_info "mounting loop device '$LOOP_DEVICE' on '$LOOP_MOUNT_POINT' ..."
  exec_cmd "$CMD_mount" "$@" -t "$FSTYPE" "$LOOP_DEVICE" "$LOOP_MOUNT_POINT"
  log_info "loop device '$LOOP_DEVICE' mounted successfully."
  
  CLEANUP_3="'$CMD_rmdir' $LOOP_MOUNT_POINT"
  CLEANUP_4="'$CMD_umount' $LOOP_DEVICE"
}
mount_loop_file


move_device_contents_into_loop_file() {

  if test "$OPT_PREALLOC" = yes; then
    log_info "preallocating loop file contents."
    log_info "this may take some time, please be patient..."
    
    OPTS_fsmove="$OPTS_fsmove --io=prealloc"
  else
    log_info "preliminary steps completed, now comes the delicate part:"
    log_info "$PROG will move '$DEVICE' contents into the loop file."

    log_warn "THIS IS IMPORTANT! if either the original device '$DEVICE'"
    log_warn_add "or the loop device '$LOOP_DEVICE' become FULL,"
    log_warn_add
    log_warn_add " YOU  WILL  LOSE  YOUR  DATA !"
    log_warn_add
    log_warn_add "$PROG checks for enough available space,"
    log_warn_add "in any case it is recommended to open another terminal, type"
    log_warn_add "  watch df $DEVICE $LOOP_DEVICE"
    log_warn_add "and check that both the original device '$DEVICE'"
    log_warn_add "and the loop device '$LOOP_DEVICE' are NOT becoming full."
    log_warn_add "if one of them is becoming full (or both),"
    log_warn_add "you MUST stop $PROG with CTRL+C or equivalent."
    log_warn_add
    if test "$OPT_ASK_QUESTIONS" = "extra"; then
      log_warn_add "this is your chance to quit."
      log_warn_add_prompt "press ENTER to continue, or CTRL+C to quit: "
      read_user_answer
    fi
    log_info "moving '$DEVICE' contents into the loop file."
    log_info "this may take a long time, please be patient..."
    
    # do not remove $LOOP_FILE anymore: in a moment it will contain users' data!
    CLEANUP_1=
  fi
  
  exec_cmd "$CMD_fsmove" $OPTS_fsmove -- "$DEVICE_MOUNT_POINT" "$LOOP_MOUNT_POINT" --exclude "$LOOP_FILE"
}
move_device_contents_into_loop_file

umount_and_fsck_loop_file() {
  log_info "unmounting and running '$CMD_fsck_target' (disk check) on loop file '$LOOP_FILE'"
  exec_cmd "$CMD_umount" "$LOOP_DEVICE"
  
  CLEANUP_4=

  exec_cmd_fsck "$CMD_fsck_target" $OPTS_fsck_target "$LOOP_DEVICE"
  exec_cmd "$CMD_sync"

  if test "$X_COPY_LOOP_FILE" != ""; then
    log_info "(internal option) copying loop file '$LOOP_FILE' to '$X_COPY_LOOP_FILE'"
    exec_cmd "$CMD_dd" bs=64k if="$LOOP_DEVICE" of="$X_COPY_LOOP_FILE"
  fi
}
umount_and_fsck_loop_file

disconnect_loop_device

clear_loop_file_prealloc_flag() {
  if test "$OPT_PREALLOC" = yes; then
    log_info "executing 'fsattr' to clear preallocation flags inside loop file '$LOOP_FILE'"
    exec_cmd "$CMD_fsattr" --fstype="$FSTYPE" --files=normal "$LOOP_FILE"
  fi
}
clear_loop_file_prealloc_flag


create_zero_file() {
  if test "$OPT_CREATE_ZERO_FILE" != "yes"; then
    return 0
  fi
  create_loop_or_zero_file zero ZERO_FILE "$ZERO_FILE"
  
  CLEANUP_5="'$CMD_rm' -f '$ZERO_FILE'"
  
  log_info "filling '$ZERO_FILE' with zeroes until device '$DEVICE' is full"
  log_info_add "needed by '$CMD_fsremap' to locate unused space."
  log_info_add "this may take a while, please be patient..."

  # trying to fill a device until it fails with "no space left on device" is not very nice
  # and can probably cause file-system corruption if device happens to be a loop-mounted file
  # which contains non-synced data.
  # to be safe, we 'sync' BEFORE and AFTER filling the device
  exec_cmd "$CMD_sync"

  # next command will fail with "no space left on device".
  # this is normal and expected.
  "$CMD_dd" if=/dev/zero of="$ZERO_FILE" bs=64k >/dev/null 2>/dev/null
  
  exec_cmd "$CMD_sync"
  log_info "file full of zeroes created successfully"
}
create_zero_file

remount_device_ro_and_fsck() {
  #log_info "remounting device '$DEVICE' read-only"
  #exec_cmd "$CMD_mount" "$DEVICE" -o remount,ro
  #exec_cmd "$CMD_sync"

  # cannot safely perform disk check on a mounted device... it must be unmounted first!
  log_info "unmounting device '$DEVICE' before disk check"
  exec_cmd "$CMD_umount" "$DEVICE"
  log_info "running '$CMD_fsck_source' (disk check) on device '$DEVICE'"
  exec_cmd_fsck "$CMD_fsck_source" $OPTS_fsck_source "$DEVICE"
  exec_cmd "$CMD_sync"
  
  if test "$X_COPY_DEVICE" != ""; then
    log_info "(internal option) copying device '$DEVICE' to '$X_COPY_DEVICE'"
    exec_cmd "$CMD_dd" bs=64k if="$DEVICE" of="$X_COPY_DEVICE"
  fi
  
  log_info "mounting again device '$DEVICE' read-only"
  if test "$DEVICE_FSTYPE" != ""; then
    exec_cmd "$CMD_mount" -t "$DEVICE_FSTYPE" "$DEVICE" "$DEVICE_MOUNT_POINT" -o ro
  else
    exec_cmd "$CMD_mount" "$DEVICE" "$DEVICE_MOUNT_POINT" -o ro
  fi
}
remount_device_ro_and_fsck



reconnect_and_remount_ro_loop_device_for_prealloc() {
  # losetup option "-r" means read-only
  connect_loop_device "-r"
  
  # mount option "-o ro" means read-only
  mount_loop_file "-o" "ro"

  # update 'fsremap' options  
  OPTS_fsremap="$OPTS_fsremap --io=prealloc --device-mount-point=$DEVICE_MOUNT_POINT --loop-mount-point=$LOOP_MOUNT_POINT --loop-device=$LOOP_DEVICE --cmd-losetup=$CMD_losetup"
}
if test "$OPT_PREALLOC" = yes; then
  reconnect_and_remount_ro_loop_device_for_prealloc
fi



remap_device_and_sync() {
  local my_OPTS_fsremap="--questions=$OPT_ASK_QUESTIONS $OPTS_fsremap"
  
  log_info "launching '$CMD_fsremap' in simulated mode"
  if test "$OPT_CREATE_ZERO_FILE" = "yes"; then
    exec_cmd "$CMD_fsremap" -q $my_OPTS_fsremap -n -- "$DEVICE" "$LOOP_FILE" "$ZERO_FILE"
  else
    exec_cmd "$CMD_fsremap" -q $my_OPTS_fsremap -n -- "$DEVICE" "$LOOP_FILE"
  fi
  
  log_info "launching '$CMD_fsremap' in REAL mode to perform in-place remapping."
  
  # starting to remap device, $ZERO_FILE will not exist anymore
  CLEANUP_5=
  
  if test "$OPT_CREATE_ZERO_FILE" = "yes"; then
    exec_cmd "$CMD_fsremap" -q $my_OPTS_fsremap --cmd-umount="$CMD_umount" -- "$DEVICE" "$LOOP_FILE" "$ZERO_FILE"
  else
    exec_cmd "$CMD_fsremap" -q $my_OPTS_fsremap --cmd-umount="$CMD_umount" -- "$DEVICE" "$LOOP_FILE"
  fi
  
  exec_cmd "$CMD_sync"
  

  if test "$X_COPY_LOOP_FILE" != ""; then
    log_info "(internal option) comparing transformed device '$DEVICE' with previously saved loop file '$X_COPY_LOOP_FILE'"
    
    # loop file may be smaller than device...
    # more exactly its length will be = device length rounded down to device block size
    "$CMD_dd" if="$DEVICE" bs="$DEVICE_BLOCK_SIZE" count="$DEVICE_SIZE_IN_BLOCKS" | "$CMD_cmp" - "$X_COPY_LOOP_FILE" || exit 1
  fi
}
remap_device_and_sync

fsck_device() {
  log_info "running again '$CMD_fsck_target' (disk check) on device '$DEVICE'"
  exec_cmd_fsck "$CMD_fsck_target" $OPTS_fsck_target "$DEVICE"
}
fsck_device


final_mount_device() {
  log_info "mounting transformed device '$DEVICE'"
  exec_cmd "$CMD_mount" -t "$FSTYPE" "$DEVICE" "$DEVICE_MOUNT_POINT"
  log_info "completed successfully. your new '$FSTYPE' file-system is mounted at '$DEVICE_MOUNT_POINT'"
}

if test "$DEVICE_IS_INITIALLY_MOUNTED" = "yes"; then
  final_mount_device
else
  log_info "completed successfully. device '$DEVICE' now contains '$FSTYPE' file-system"
fi

