#!/bin/sh
#-
# Copyright (c) 2016 Devin Teske
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# $FreeBSD$
#
############################################################ IDENT(1)
#
# $Title: if_bridge(4) management script for vnet jails $
#
############################################################ INFORMATION
#
# Use this tool with jail.conf(5) (or rc.conf(5) ``legacy'' configuration) to
# manage `vnet' interfaces for jails. Designed to automate the creation of vnet
# interface(s) during jail `prestart' and destroy said interface(s) during jail
# `poststop'.
#
# In jail.conf(5) format:
#
# ### BEGIN EXCERPT ###
#
# xxx {
#       host.hostname = "xxx.yyy";
#       path = "/vm/xxx";
#
#       #
#       # NB: Below 2-lines required
#       # NB: The number of eNb_xxx interfaces should match the number of
#       #     arguments given to `jib addm xxx' in exec.prestart value.
#       #
#       vnet;
#       vnet.interface = e0b_xxx, e1b_xxx, ...;
#
#       exec.clean;
#       exec.system_user = "root";
#       exec.jail_user = "root";
#
#       #
#       # NB: Below 2-lines required
#       # NB: The number of arguments after `jib addm xxx' should match
#       #     the number of eNb_xxx arguments in vnet.interface value.
#       #
#       exec.prestart += "jib addm xxx em0 em1 ...";
#       exec.poststop += "jib destroy xxx";
#
#       # Standard recipe
#       exec.start += "/bin/sh /etc/rc";
#       exec.stop = "/bin/sh /etc/rc.shutdown jail";
#       exec.consolelog = "/var/log/jail_xxx_console.log";
#       mount.devfs;
#
#       # Optional (default off)
#       #allow.mount;
#       #allow.set_hostname = 1;
#       #allow.sysvipc = 1;
#       #devfs_ruleset = "11"; # rule to unhide bpf for DHCP
# }
#
# ### END EXCERPT ###
#
# In rc.conf(5) ``legacy'' format (used when /etc/jail.conf does not exist):
#
# ### BEGIN EXCERPT ###
#
# jail_enable="YES"
# jail_list="xxx"
#
# #
# # Global presets for all jails
# #
# jail_devfs_enable="YES"	# mount devfs
#
# #
# # Global options (default off)
# #
# #jail_mount_enable="YES"		# mount /etc/fstab.{name}
# #jail_set_hostname_allow="YES"	# Allow hostname to change
# #jail_sysvipc_allow="YES"		# Allow SysV Interprocess Comm.
#
# # xxx
# jail_xxx_hostname="xxx.shxd.cx"		# hostname
# jail_xxx_rootdir="/vm/xxx"			# root directory
# jail_xxx_vnet_interfaces="e0b_xxx e1bxxx ..."	# vnet interface(s)
# jail_xxx_exec_prestart0="jib addm xxx em0 em1 ..."	# bridge interface(s)
# jail_xxx_exec_poststop0="jib destroy xxx"	# destroy interface(s)
# #jail_xxx_mount_enable="YES"			# mount /etc/fstab.xxx
# #jail_xxx_devfs_ruleset="11"			# rule to unhide bpf for DHCP
#
# ### END EXCERPT ###
#
# Note that the legacy rc.conf(5) format is converted to
# /var/run/jail.{name}.conf by /etc/rc.d/jail if jail.conf(5) is missing.
#
# ASIDE: dhclient(8) inside a vnet jail...
#
# To allow dhclient(8) to work inside a vnet jail, make sure the following
# appears in /etc/devfs.rules (which should be created if it doesn't exist):
#
#       [devfsrules_jail=11]
#       add include $devfsrules_hide_all
#       add include $devfsrules_unhide_basic
#       add include $devfsrules_unhide_login
#       add path 'bpf*' unhide
#
# And set ether devfs.ruleset="11" (jail.conf(5)) or
# jail_{name}_devfs_ruleset="11" (rc.conf(5)).
#
# NB: While this tool can't create every type of desirable topology, it should
# handle most setups, minus some which considered exotic or purpose-built.
#
############################################################ GLOBALS


# MY SIMPLE JIB -- steve
#
# Reasoning:
# - my jail host has 22 if_bridges, i have no idea where they came from, i'm blaming old jib
# - old jib assumes you have a physical NIC which my virtual test environment does not
# - old jib has a complex mac creation algorithm. i think this is due to mac conflict bugs
#   in the early days of if_epair https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=176671
#   which seems to have been fixed since 2016
#
# Changes:
# - don't create bridges
# - use the requested ifname for the epair
# - create an epair using ifconfig(8), add it to desired bridge, rename, up
# - old jib is now simple jib :)

pgm="${0##*/}" # Program basename

#
# Global exit status
#
SUCCESS=0
FAILURE=1

############################################################ FUNCTIONS

usage()
{
        local action usage descr
        exec >&2
        echo "Usage: $pgm action [arguments]"
        echo "Actions:"
        for action in \
                addm		\
                destroy		\
        ; do
                eval usage=\"\$jib_${action}_usage\"
                [ "$usage" ] || continue
                eval descr=\"\$jib_${action}_descr\"
                printf "\t%s\n\t\t%s\n" "$usage" "$descr"
        done
        exit $FAILURE
}

action_usage()
{
        local usage descr action="$1"
        eval usage=\"\$jib_${action}_usage\"
        echo "Usage: $pgm $usage" >&2
        eval descr=\"\$jib_${action}_descr\"
        printf "\t%s\n" "$descr"
        exit $FAILURE
}

mustberoot_to_continue()
{
        if [ "$( id -u )" -ne 0 ]; then
                echo "Must run as root!" >&2
                exit $FAILURE
        fi
}

jib_addm_usage="addm BRIDGE_NAME NAME"
jib_addm_descr="Creates epair NAME and adds to bridge BRIDGE_NAME"
jib_addm()
{
        local bridge="$1"
        local name="$2"

        mustberoot_to_continue

        # Make sure the interface doesn't exist already
        if ifconfig "${name}a" > /dev/null 2>&1; then
                return
        fi

        # Create a new interface to the bridge
        local new=$( ifconfig epair create ) || return
        ifconfig "$bridge" addm $new || return

        # Rename the new interface
        ifconfig $new name "${name}a" || return
        ifconfig ${new%a}b name "${name}b" || return
        ifconfig "${name}a" up || return
        ifconfig "${name}b" up || return
}

############################################################ MAIN

#
# Command-line arguments
#
action="$1"
[ "$action" ] || usage # NOTREACHED

#
# Validate action argument
#
if [ "$BASH_VERSION" ]; then
        type="$( type -t "jib_$action" )" || usage # NOTREACHED
else
        type="$( type "jib_$action" 2> /dev/null )" || usage # NOTREACHED
fi
case "$type" in
*function)
        shift 1 # action
        eval "jib_$action" \"\$@\"
        ;;
*) usage # NOTREACHED
esac

################################################################################
# END
################################################################################
