#!/bin/bash
#
# Common support functions for testing scripts.  If a .script-config
# files is available it will be sourced so in-tree kernel modules and
# utilities will be used.  If no .script-config can be found then the
# installed kernel modules and utilities will be used.

basedir="$(dirname $0)"

SCRIPT_CONFIG=.script-config
if [ -f "${basedir}/../${SCRIPT_CONFIG}" ]; then
. "${basedir}/../${SCRIPT_CONFIG}"
else
MODULES=(zlib_deflate spl splat zavl znvpair zunicode zcommon zfs)
fi

PROG="<define PROG>"
CLEANUP=
VERBOSE=
VERBOSE_FLAG=
FORCE=
FORCE_FLAG=
DUMP_LOG=
ERROR=
RAID0S=()
RAID10S=()
RAIDZS=()
RAIDZ2S=()
TESTS_RUN=${TESTS_RUN:-'*'}
TESTS_SKIP=${TESTS_SKIP:-}

prefix=/usr/local
exec_prefix=${prefix}
libexecdir=${exec_prefix}/libexec
pkglibexecdir=${libexecdir}/zfs
bindir=${exec_prefix}/bin
sbindir=${exec_prefix}/sbin

ETCDIR=${ETCDIR:-/etc}
DEVDIR=${DEVDIR:-/dev/disk/zpool}
ZPOOLDIR=${ZPOOLDIR:-${pkglibexecdir}/zpool-config}
ZPIOSDIR=${ZPIOSDIR:-${pkglibexecdir}/zpios-test}
ZPIOSPROFILEDIR=${ZPIOSPROFILEDIR:-${pkglibexecdir}/zpios-profile}

ZDB=${ZDB:-${sbindir}/zdb}
ZFS=${ZFS:-${sbindir}/zfs}
ZINJECT=${ZINJECT:-${sbindir}/zinject}
ZPOOL=${ZPOOL:-${sbindir}/zpool}
ZPOOL_ID=${ZPOOL_ID:-${bindir}/zpool_id}
ZTEST=${ZTEST:-${sbindir}/ztest}
ZPIOS=${ZPIOS:-${sbindir}/zpios}

COMMON_SH=${COMMON_SH:-${pkglibexecdir}/common.sh}
ZFS_SH=${ZFS_SH:-${pkglibexecdir}/zfs.sh}
ZPOOL_CREATE_SH=${ZPOOL_CREATE_SH:-${pkglibexecdir}/zpool-create.sh}
ZPIOS_SH=${ZPIOS_SH:-${pkglibexecdir}/zpios.sh}
ZPIOS_SURVEY_SH=${ZPIOS_SURVEY_SH:-${pkglibexecdir}/zpios-survey.sh}

LDMOD=${LDMOD:-/sbin/modprobe}
LSMOD=${LSMOD:-/sbin/lsmod}
RMMOD=${RMMOD:-/sbin/rmmod}
INFOMOD=${INFOMOD:-/sbin/modinfo}
LOSETUP=${LOSETUP:-/sbin/losetup}
SYSCTL=${SYSCTL:-/sbin/sysctl}
UDEVADM=${UDEVADM:-/sbin/udevadm}
AWK=${AWK:-/usr/bin/awk}

COLOR_BLACK="\033[0;30m"
COLOR_DK_GRAY="\033[1;30m"
COLOR_BLUE="\033[0;34m"
COLOR_LT_BLUE="\033[1;34m" 
COLOR_GREEN="\033[0;32m"
COLOR_LT_GREEN="\033[1;32m"
COLOR_CYAN="\033[0;36m"
COLOR_LT_CYAN="\033[1;36m"
COLOR_RED="\033[0;31m"
COLOR_LT_RED="\033[1;31m"
COLOR_PURPLE="\033[0;35m"
COLOR_LT_PURPLE="\033[1;35m"
COLOR_BROWN="\033[0;33m"
COLOR_YELLOW="\033[1;33m"
COLOR_LT_GRAY="\033[0;37m"
COLOR_WHITE="\033[1;37m"
COLOR_RESET="\033[0m"

die() {
	echo -e "${PROG}: $1" >&2
	exit 1
}

msg() {
	if [ ${VERBOSE} ]; then
		echo "$@"
	fi
}

pass() {
	echo -e "${COLOR_GREEN}Pass${COLOR_RESET}"
}

fail() {
	echo -e "${COLOR_RED}Fail${COLOR_RESET} ($1)"
	exit $1
}

skip() {
	echo -e "${COLOR_BROWN}Skip${COLOR_RESET}"
}

spl_dump_log() {
	${SYSCTL} -w kernel.spl.debug.dump=1 &>/dev/null
	local NAME=`dmesg | tail -n 1 | cut -f5 -d' '`
	${SPLBUILD}/cmd/spl ${NAME} >${NAME}.log
	echo
	echo "Dumped debug log: ${NAME}.log"
	tail -n1 ${NAME}.log
	echo
	return 0
}

check_modules() {
	local LOADED_MODULES=()
	local MISSING_MODULES=()

	for MOD in ${MODULES[*]}; do
		local NAME=`basename $MOD .ko`

		if ${LSMOD} | egrep -q "^${NAME}"; then
			LOADED_MODULES=(${NAME} ${LOADED_MODULES[*]})
		fi

		if [ ${INFOMOD} ${MOD} 2>/dev/null ]; then
			MISSING_MODULES=("\t${MOD}\n" ${MISSING_MODULES[*]})
		fi
	done

	if [ ${#LOADED_MODULES[*]} -gt 0 ]; then
		ERROR="Unload these modules with '${PROG} -u':\n"
		ERROR="${ERROR}${LOADED_MODULES[*]}"
		return 1
	fi

	if [ ${#MISSING_MODULES[*]} -gt 0 ]; then
		ERROR="The following modules can not be found,"
		ERROR="${ERROR} ensure your source trees are built:\n"
		ERROR="${ERROR}${MISSING_MODULES[*]}"
		return 1
	fi

	return 0
}

load_module() {
	local NAME=`basename $1 .ko`

	if [ ${VERBOSE} ]; then
		echo "Loading ${NAME} ($@)"
	fi

	${LDMOD} $* || ERROR="Failed to load $1" return 1

	return 0
}

load_modules() {
	mkdir -p /etc/zfs

	for MOD in ${MODULES[*]}; do
		local NAME=`basename ${MOD} .ko`
		local VALUE=

		for OPT in "$@"; do
			OPT_NAME=`echo ${OPT} | cut -f1 -d'='`

			if [ ${NAME} = "${OPT_NAME}" ]; then
				VALUE=`echo ${OPT} | cut -f2- -d'='`
			fi
		done

		load_module ${MOD} ${VALUE} || return 1
	done

	if [ ${VERBOSE} ]; then
		echo "Successfully loaded ZFS module stack"
	fi

	return 0
}

unload_module() {
	local NAME=`basename $1 .ko`

	if [ ${VERBOSE} ]; then
		echo "Unloading ${NAME} ($@)"
	fi

	${RMMOD} ${NAME} || ERROR="Failed to unload ${NAME}" return 1

	return 0
}

unload_modules() {
	local MODULES_REVERSE=( $(echo ${MODULES[@]} |
		${AWK} '{for (i=NF;i>=1;i--) printf $i" "} END{print ""}') )

	for MOD in ${MODULES_REVERSE[*]}; do
		local NAME=`basename ${MOD} .ko`
		local USE_COUNT=`${LSMOD} |
				egrep "^${NAME} "| ${AWK} '{print $3}'`

		if [ "${USE_COUNT}" = 0 ] ; then

			if [ "${DUMP_LOG}" -a ${NAME} = "spl" ]; then
				spl_dump_log
			fi

			unload_module ${MOD} || return 1
		fi
	done

	if [ ${VERBOSE} ]; then
		echo "Successfully unloaded ZFS module stack"
	fi

	return 0
}

unused_loop_device() {
	for DEVICE in `ls -1 /dev/loop*`; do
		${LOSETUP} ${DEVICE} &>/dev/null
		if [ $? -ne 0 ]; then
			echo ${DEVICE}
			return
		fi
	done

	die "Error: Unable to find unused loopback device"
}

#
# This can be slightly dangerous because the loop devices we are
# cleanup up may not be ours.  However, if the devices are currently
# in use we will not be able to remove them, and we only remove
# devices which include 'zpool' in the name.  So any damage we might
# do should be limited to other zfs related testing.
#
cleanup_loop_devices() {
	local TMP_FILE=`mktemp`

	${LOSETUP} -a | tr -d '()' >${TMP_FILE}
	${AWK} -F":" -v losetup="$LOSETUP" \
	    '/zpool/ { system("losetup -d "$1) }' ${TMP_FILE}
	${AWK} -F" " '/zpool/ { system("rm -f "$3) }' ${TMP_FILE}

	rm -f ${TMP_FILE}
}

#
# The following udev helper functions assume that the provided
# udev rules file will create a /dev/disk/zpool/<CHANNEL><RANK>
# disk mapping.  In this mapping each CHANNEL is represented by
# the letters a-z, and the RANK is represented by the numbers
# 1-n.  A CHANNEL should identify a group of RANKS which are all
# attached to a single controller, each RANK represents a disk.
# This provides a simply mechanism to locate a specific drive
# given a known hardware configuration.
#
udev_setup() {
	local SRC_PATH=$1

	# When running in tree manually contruct symlinks in tree to
	# the proper devices.  Symlinks are installed for all entires
	# in the config file regardless of if that device actually
	# exists.  When installed as a package udev can be relied on for
	# this and it will only create links for devices which exist.
	if [ ${INTREE} ]; then
		PWD=`pwd`
		mkdir -p ${DEVDIR}/
		cd ${DEVDIR}/
		${AWK} '!/^#/ && /./ { system( \
			"ln -f -s /dev/disk/by-path/"$2" "$1";" \
			"ln -f -s /dev/disk/by-path/"$2"-part1 "$1"p1;" \
			"ln -f -s /dev/disk/by-path/"$2"-part9 "$1"p9;" \
			) }' $SRC_PATH
		cd ${PWD}
	else
		DST_FILE=`basename ${SRC_PATH} | cut -f1-2 -d'.'`
		DST_PATH=/etc/zfs/${DST_FILE}

		if [ -e ${DST_PATH} ]; then
			die "Error: Config ${DST_PATH} already exists"
		fi

		cp ${SRC_PATH} ${DST_PATH}

		if [ -f ${UDEVADM} ]; then
			${UDEVADM} trigger
			${UDEVADM} settle
		else
			/sbin/udevtrigger
			/sbin/udevsettle
		fi
	fi

	return 0
}

udev_cleanup() {
	local SRC_PATH=$1

	if [ ${INTREE} ]; then
		PWD=`pwd`
		cd ${DEVDIR}/
		${AWK} '!/^#/ && /./ { system( \
			"rm -f "$1" "$1"p1 "$1"p9") }' $SRC_PATH
		cd ${PWD}
	fi

	return 0
}

udev_cr2d() {
	local CHANNEL=`echo "obase=16; $1+96" | bc`
	local RANK=$2

	printf "\x${CHANNEL}${RANK}"
}

udev_raid0_setup() {
	local RANKS=$1
	local CHANNELS=$2
	local IDX=0

	RAID0S=()
	for RANK in `seq 1 ${RANKS}`; do
		for CHANNEL in `seq 1 ${CHANNELS}`; do
			DISK=`udev_cr2d ${CHANNEL} ${RANK}`
			RAID0S[${IDX}]="${DEVDIR}/${DISK}"
			let IDX=IDX+1
		done
	done

	return 0
}

udev_raid10_setup() {
	local RANKS=$1
	local CHANNELS=$2
	local IDX=0

	RAID10S=()
	for RANK in `seq 1 ${RANKS}`; do
		for CHANNEL1 in `seq 1 2 ${CHANNELS}`; do
			let CHANNEL2=CHANNEL1+1
			DISK1=`udev_cr2d ${CHANNEL1} ${RANK}`
			DISK2=`udev_cr2d ${CHANNEL2} ${RANK}`
			GROUP="${DEVDIR}/${DISK1} ${DEVDIR}/${DISK2}"
			RAID10S[${IDX}]="mirror ${GROUP}"
			let IDX=IDX+1
		done
	done

	return 0
}

udev_raidz_setup() {
	local RANKS=$1
	local CHANNELS=$2

	RAIDZS=()
	for RANK in `seq 1 ${RANKS}`; do
		RAIDZ=("raidz")

		for CHANNEL in `seq 1 ${CHANNELS}`; do
			DISK=`udev_cr2d ${CHANNEL} ${RANK}`
			RAIDZ[${CHANNEL}]="${DEVDIR}/${DISK}"
		done

		RAIDZS[${RANK}]="${RAIDZ[*]}"
	done

	return 0
}

udev_raidz2_setup() {
	local RANKS=$1
	local CHANNELS=$2

	RAIDZ2S=()
	for RANK in `seq 1 ${RANKS}`; do
		RAIDZ2=("raidz2")

		for CHANNEL in `seq 1 ${CHANNELS}`; do
			DISK=`udev_cr2d ${CHANNEL} ${RANK}`
			RAIDZ2[${CHANNEL}]="${DEVDIR}/${DISK}"
		done

		RAIDZ2S[${RANK}]="${RAIDZ2[*]}"
	done

	return 0
}

run_one_test() {
	local TEST_NUM=$1
	local TEST_NAME=$2

	printf "%-4d %-36s " ${TEST_NUM} "${TEST_NAME}"
	test_${TEST_NUM}
}

skip_one_test() {
	local TEST_NUM=$1
	local TEST_NAME=$2

	printf "%-4d %-36s " ${TEST_NUM} "${TEST_NAME}"
	skip
}

run_test() {
	local TEST_NUM=$1
	local TEST_NAME=$2

	for i in ${TESTS_SKIP[@]}; do
		if [[ $i == ${TEST_NUM} ]] ; then
			skip_one_test ${TEST_NUM} "${TEST_NAME}"
			return 0
		fi
	done

	if [ "${TESTS_RUN[0]}" = "*" ]; then
		run_one_test ${TEST_NUM} "${TEST_NAME}"
	else
		for i in ${TESTS_RUN[@]}; do
			if [[ $i == ${TEST_NUM} ]] ; then
				run_one_test ${TEST_NUM} "${TEST_NAME}"
				return 0
			fi
		done

		skip_one_test ${TEST_NUM} "${TEST_NAME}"
	fi
}