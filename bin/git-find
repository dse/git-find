#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
shopt -s lastpipe

# git-find.sh                   lists your repositories
# git-find.sh git remote -v     executes a git (or other) cmd in each repos

# --follow
# --inline
# --quiet
# --width=NUMBER
# --no-header
# --pager

main () {
    declare -i optshift
    declare -a git_find_expr=()
    declare -a find_options=()
    declare -a find_targets=()
    declare -a git_cmd=()
    declare -a find_expr=()
    declare -a includes=()
    declare -a excludes=()
    color=auto
    COLOR_ON=''
    COLOR_OFF=''
    dry_run=0

    get_options      "$@"; shift $optshift
    get_find_options "$@"; shift $optshift
    get_git_command  "$@"; shift $optshift
    get_find_options "$@"; shift $optshift
    get_find_targets "$@"; shift $optshift
    get_find_expr    "$@"; shift $optshift

    case "${color}" in
        never) COLOR_ON=''; COLOR_OFF='';;
        auto)
            if [[ -t 1 ]] ; then
                COLOR_ON=$'\e[32m'; COLOR_OFF=$'\e[0m'
            fi;;
        always)
            COLOR_ON=$'\e[32m'; COLOR_OFF=$'\e[0m'
            ;;
    esac

    if (( ! ${#find_targets[@]} )) ; then
        find_targets+=(.)
    fi

    if (( !${#git_cmd[@]} )) ; then
        git_find_expr=(-print)
    else
        if [[ "${git_cmd[0]}" = "git" ]] ; then
            unset git_cmd[0]
            git_cmd=(
                env -C '{}' git --no-pager "${git_cmd[@]}"
            )
        else
            git_cmd=(
                env -C '{}' "${git_cmd[@]}"
            )
        fi
        git_find_expr=(-printf "${COLOR_ON}==> %p <==${COLOR_OFF}\\n" -exec "${git_cmd[@]}" \;)
    fi

    if (( ${#includes[@]} )) ; then
        includes=(
            \( "${includes[@]}" \)
        )
    fi
    if (( ${#excludes[@]} )) ; then
        excludes=(
            \! \( \( "${excludes[@]}" \) -prune \)
        )
    fi

    if (( dry_run )) ; then
        echo "find options = ${find_options[@]}" >&2
        echo "find targets = ${find_targets[@]}" >&2
        echo "find expr    = ${find_expr[@]}" >&2
        echo "git command  = ${git_command[@]}" >&2
        echo "includes     = ${includes[@]}" >&2
        echo "excludes     = ${excludes[@]}" >&2
    fi

    declare -a progress=(
    )
    if [[ -t 1 ]] && [[ -t 2 ]] ; then
        progress=(
            -fprintf /dev/stderr "%p\033[K\015"
        )
    fi

    # runs "echo exec ..." if dry run, otherwise runs "exec ..."
    $( (( dry_run )) && echo echo ) \
        exec find "${find_options[@]}" "${find_targets[@]}" -type d \
        \! \( \( -name node_modules -o -name .git \) -prune \) \
        \! \( -name vendor -exec test -f '{}/../composer.json' \; -prune \) \
        "${progress[@]}" \
        "${excludes[@]}" \
        "${includes[@]}" \
        -exec test -d '{}/.git' \; \
        -prune \
        "${git_find_expr[@]}"
}

include () {
    for i ; do
        if (( ${#includes[@]} )) ; then
            includes+=(-o)
        fi
        includes+=(-name "$i")
    done
}

exclude () {
    for i ; do
        if (( ${#excludes[@]} )) ; then
            excludes+=(-o)
        fi
        excludes+=(-name "$i")
    done
}

get_find_options () {
    optshift=0
    while (( $# )) ; do
        case "$1" in
            -H|-L|-P) find_options+=("$1"); optshift+=1; shift;;
            -D|-O)    if (( $# < 2 )) ; then usage >&2 ; exit 1 ; fi
                      find_options+=("$1" "$2"); optshift+=2; shift 2;;
            -D*|-O*)  find_options+=("$1"); optshift+=1; shift;;
            *)        break;;
        esac
    done
}

get_git_command () {
    optshift=0
    while (( $# )) ; do
        case "$1" in
            \;\;)     optshift+=1; break;;
            *)        git_cmd+=("$1"); optshift+=1; shift;;
        esac
    done
}

get_find_targets () {
    optshift=0
    while (( $# )) ; do
        case "$1" in
            -*|\(|\!) break;;
            *)        find_targets+=("$1"); optshift+=1; shift;;
        esac
    done
}

get_find_expr () {
    optshift=0
    while (( $# )) ; do
        find_expr+=("$1"); optshift+=1; shift
    done
}

get_options () {
    optshift=0
    while (( $# )) ; do
        case "$1" in
            --help)
                usage; exit 0;;

            --target)
                if (( $# < 2 )) ; then echo "option $1 requires an argument" >&2; exit 1; fi
                find_targets+=("$2"); optshift+=2; shift 2;;
            -t)
                if (( $# < 2 )) ; then echo "option $1 requires an argument" >&2; exit 1; fi
                find_targets+=("$2"); optshift+=2; shift 2;;
            --target=*)
                find_targets+=("${1#*=}"); optshift+=1; shift;;
            -t*)
                find_targets+=("${1#-t}"); optshift+=1; shift;;

            --dry-run)
                dry_run=1; optshift+=1; shift;;
            -n)
                dry_run=1; optshift+=1; shift;;

            --color)
                color=always; optshift+=1; shift;;
            --color=never)
                color=never; optshift+=1; shift;;
            --color=auto)
                color=auto; optshift+=1; shift;;
            --color=always)
                color=always; optshift+=1; shift;;

            --include)
                if (( $# < 2 )) ; then echo "option $1 requires an argument" >&2; exit 1; fi
                include "$2"; optshift+=2; shift 2;;
            --exclude)
                if (( $# < 2 )) ; then echo "option $1 requires an argument" >&2; exit 1; fi
                exclude "$2"; optshift+=2; shift 2;;
            --include=*)
                include "${1#*=}"; optshift+=1; shift;;
            --exclude=*)
                exclude "${1#*=}"; optshift+=1; shift;;

            --*)
                echo "illegal option -- $1" >&2; exit 1;;
            *)
                break;;
        esac
    done
}

usage () { cat <<EOF; }
git find [OPTIONS] [FIND_OPTIONS] [CMD ...]
git find [OPTIONS] [FIND_OPTIONS] [CMD ...] \;\; [FIND_OPTIONS] [DIR ...]
                                                                [FIND_EXPR ...]
    FIND_OPTIONS and FIND_EXPR are the same as in find(1).
    CMD does not include "git" automatically; you must specify it.
OPTIONS: (these must come before the FIND_OPTIONS)
    --include=WILDCARD
    --exclude=WILDCARD
    --color[=auto|=always|=never]
    --dry-run
EOF

#------------------------------------------------------------------------------
main "$@"
