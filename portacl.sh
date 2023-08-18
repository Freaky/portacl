#!/bin/sh
#
# $FreeBSD$

# PROVIDE: portacl
# REQUIRE: FILESYSTEMS
# BEFORE: SERVERS
# KEYWORD: nojail

. /etc/rc.subr

name="portacl"
desc="Network port access control policy"
rcvar="portacl_enable"
extra_commands="reload"
start_cmd="portacl_start"
restart_cmd="portacl_start"
reload_cmd="portacl_start"
stop_cmd="portacl_stop"
required_modules="mac_portacl"

: "${portacl_enable:="NO"}"
: "${portacl_port_high:="1023"}"
: "${portacl_suser_exempt:="YES"}"
: "${portacl_autoport_exempt:="YES"}"
: "${portacl_users:=""}"
: "${portacl_groups:=""}"
: "${portacl_additional_rules:=""}"

# If the value is numeric, echo it and return true
echo_numeric()
{
	case "${1}" in
	''|*[!0-9]*)
		return 1
		;;
	*)
		echo "${1}"
		return 0
		;;
	esac
}

split_comma()
{
	local rule
	local IFS=','
	for rule in $1
	do
		echo "${rule}"
	done
}

join_uniq()
{
	sort -ut : | paste -s -d ',' -
}

resolve_port()
{
	local port proto lookup

	port=$1
	proto=$2

	echo_numeric "${port}" && return

	# ensure port is ^[a-z0-9]$
	case "${port}" in
	''|*[!a-z0-9]*)
		warn "invalid service name: ${port}"
		return 1
		;;
	*)
		;;
	esac

	lookup=$(/usr/bin/awk -F'[/[:space:]]+' "/^${port}[\t ]+([0-9]+)\/${proto}/ { print \$2 ; exit 0 }" /etc/services)

	if [ -z "${lookup}" ]; then
		warn "unknown service ${port}"
		return
	fi

	echo "${lookup}"
}

resolve_id() {
	local id flag kind lookup

	kind=$1
	id=$2

	case "${kind}" in
	user)
		flag="-u"
		;;
	group)
		flag="-g"
		;;
	*)
		warn "Not one of user or group: ${kind}"
		return
	esac

	echo_numeric "${id}" && return

	lookup=$(/usr/bin/id "${flag}" "${id}" 2>/dev/null)

	if [ -z "${lookup}" ]; then
		warn "unknown ${kind} ${id}"
		return
	fi

	echo "${lookup}"
}

generate_ruleset_for()
{
	local kind key sid ids id rules proto ports port
	
	kind="${1}"

	case "${kind}" in
	user)
		key="uid"
		;;
	group)
		key="gid"
		;;
	*)
		warn "Not one of user or group: ${kind}"
		return
	esac

	eval ids="\${${name}_${kind}s}"
	for sid in ${ids}
	do
		for proto in tcp udp
		do
			eval ports="\${${name}_${kind}_${sid}_${proto}}"
			id=$(resolve_id "${kind}" "${sid}")
			[ -z "${id}" ] && continue
			for port in ${ports}
			do
				port=$(resolve_port "${port}" "${proto}")
				[ -z "${port}" ] && continue
				echo "${key}:${id}:${proto}:${port}"
			done
		done
	done
}

generate_ruleset()
{
	split_comma "${portacl_additional_rules}"
	generate_ruleset_for user
	generate_ruleset_for group
}

warn_existing_rules()
{
	local f

	for f in /etc/sysctl.conf /etc/sysctl.conf.local
	do
		if [ -r ${f} ] &&  grep -qe '^[ ]*security\.mac\.portacl\.rules' "${f}"
		then
			warn "overriding existing portacl ruleset in $f"
		fi
	done
}

set_sysctl()
{
	debug "set_sysctl: ${1}=${2}"

	if ! sysctl "${1}=${2}" >/dev/null; then
		warn "failed to set sysctl ${1}"
		return 1
	fi
	return 0
}

# convert the checkyesno return value to a literal 1 or 0
# we could do with inverting the fallback to assume-yes
checkyesno_integer()
{
	if checkyesno "${1}"; then
		echo 1
	else
		echo 0
	fi
}

# echo the value of the variable if it is numeric
# or print a warning and echo the value of the second argument
integer_or_default()
{
	local value

	eval "value=\$${1}"
	echo_numeric "${value}" && return 0
	warn "\$${1} is not set properly, reverting to default ${2} - see rc.conf(5)"
	echo "${2}"
}

portacl_start()
{
	local rules port_high

	warn_existing_rules

	rules="$(generate_ruleset | join_uniq)"

	port_high="$(integer_or_default portacl_port_high 1023)"

	set_sysctl security.mac.portacl.rules "${rules}" &&
	set_sysctl security.mac.portacl.suser_exempt \
		"$(checkyesno_integer "portacl_suser_exempt")" &&
	set_sysctl security.mac.portacl.autoport_exempt \
		"$(checkyesno_integer "portacl_autoport_exempt")" &&
	set_sysctl security.mac.portacl.port_high "${port_high}" &&
	set_sysctl security.mac.portacl.enabled 1 &&
	set_sysctl net.inet.ip.portrange.reservedlow 0 &&
	set_sysctl net.inet.ip.portrange.reservedhigh 0
}

portacl_stop()
{
	set_sysctl net.inet.ip.portrange.reservedlow 0 &&
	set_sysctl net.inet.ip.portrange.reservedhigh 1023 &&
	set_sysctl security.mac.portacl.enabled 0
}

load_rc_config $name
run_rc_command "$1"
