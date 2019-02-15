#!/bin/env bash
exe=`basename $0`

if [ "" = "${VED}" ] ; then
    VIMPATH=/usr/software/bin
else
    VIMPATH=/usr/bin
fi

VIMPATH=/u/dhruva/installs/vim/bin
REALVIM=${VIMPATH}/${exe}

if [ -z "${INSIDE_EMACS}" ] ; then
    if [ "${TERM}" = "screen" ] ; then
	TTYPE=xterm-256color
    fi
    TERM=${TTYPE:-${TERM}} ${REALVIM} -X $*
elif [ $exe = "vim" -o $exe = "vi" ] ; then
    if [ $# -ge 1 ] ; then
	${ACTION} emacsclient -q -n $* 2>/dev/null
    fi
elif [ $exe = "vimdiff" ] ; then
    ${ACTION} emacsclient -q --eval "(ediff-files \"$1\" \"$2\")"
elif [ $exe = "emerge" -o $exe = "merge" ] ; then
    ${ACTION} emacsclient -c  --eval "(emerge-files nil \"$3\" \"$4\" \"${4}.out\")"
else
    echo GNU Emacs does not know command $exe $*
    exit -1
fi