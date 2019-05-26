#!/bin/bash

MAC="$(echo $2 | sed 's/ //g' | sed 's/-//g' | sed 's/://g' | cut -c1-6)";

result=$(LC_ALL=C grep -i ^$MAC ./oui.txt | awk 'match($0,/\).*$/) { print substr($0,RSTART+3,RLENGTH-3)}');

if [ "$result" ]; then
    echo -e "$1\t$2\t$result"
else
    echo -e "$1\t$2\tunknown"
fi
