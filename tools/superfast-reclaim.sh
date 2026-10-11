#!/bin/sh
# superfast-reclaim — the two kernel writes that hand a memory-famished host its
# contiguous 2 MiB blocks back.
#
# It is installed by deploy/setup-fedora.sh as a root-owned file in
# /usr/local/sbin, with a sudoers rule that lets the installing user run exactly
# this script and nothing else:
#
#   /etc/sudoers.d/superfast-reclaim
#   <user> ALL=(root) NOPASSWD: /usr/local/sbin/superfast-reclaim ""
#
# It takes no arguments on purpose. A sudoers rule that allowed arguments to a
# root command is a rule that can run anything, so the args are forbidden with
# "" and this script never needs one.
#
# Why these two writes, and not "free memory" in general:
#
#   drop_caches     the engine's 47.7 GiB lookup table is not held in RAM: it is
#                   read through the page cache. When the rest of the system
#                   needs memory back, those are the pages that can go.
#   compact_memory  the engine allocates from contiguous 2 MiB blocks, and those
#                   are what run out first. Compaction turns scattered free pages
#                   back into blocks it can use.
#
# Measured on the reference host: free 2 MiB blocks 16 -> 537, and the engine
# then started with 0 failed compaction stalls. Nothing here is destructive:
# dropping the page cache only means the next reads come from disk again.
#
# Called by tools/superfast-recover.sh as `sudo -n /usr/local/sbin/superfast-reclaim`.
sync
echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory
