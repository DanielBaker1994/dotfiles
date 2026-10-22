# shellcheck shell=bash
# prof.sh — timing for herdr plugin handlers; read with herdr/herdr-prof.sh.
#
# Sourced at the top of each plugin script. Every run appends one line to
# $state/handlers.log at exit:
#   START_EPOCH <TAB> TOTAL_MS <TAB> WAIT_MS <TAB> SCRIPT <TAB> ARGS (EVENT)
# WAIT_MS = time spent queued on a lock (prof_wait_start / prof_wait_end
# around it), the sign of handlers piling up behind each other.
# Builtins only, so it costs microseconds and stays on all the time.
#   $state/off    -> no logging
#   $state/trace  -> also `set -x` each run into $state/traces/ (line-level
#                    cost, summed by herdr-prof.sh trace)
# Scripts with their own EXIT trap call prof_end in it. Needs bash 5+
# (EPOCHREALTIME); on an older bash every prof_* is a no-op.

_prof_state="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-prof"
prof_wait_start() { :; }
prof_wait_end() { :; }
prof_end() { :; }

if [[ -n ${EPOCHREALTIME:-} && ! -e $_prof_state/off ]]; then
    _prof_t0=$EPOCHREALTIME
    _prof_wait=0
    _prof_what="${0##*/}"$'\t'"$*${HERDR_PLUGIN_EVENT:+ ($HERDR_PLUGIN_EVENT)}"
    [[ -d $_prof_state ]] || mkdir -p "$_prof_state"

    # EPOCHREALTIME always has 6 decimals: drop the point -> microseconds
    prof_wait_start() { _prof_w0=$EPOCHREALTIME; }
    prof_wait_end() {
        local now=$EPOCHREALTIME
        _prof_wait=$(((${now/[.,]/} - ${_prof_w0/[.,]/}) / 1000))
    }
    prof_end() {
        local now=$EPOCHREALTIME
        if [[ -n ${_prof_trace_fd:-} ]]; then set +x; fi
        printf '%s\t%d\t%d\t%s\n' "${_prof_t0/,/.}" $(((${now/[.,]/} - ${_prof_t0/[.,]/}) / 1000)) \
            "$_prof_wait" "$_prof_what" >>"$_prof_state/handlers.log"
        prof_end() { :; }
    }
    trap prof_end EXIT

    if [[ -e $_prof_state/trace ]]; then
        [[ -d $_prof_state/traces ]] || mkdir -p "$_prof_state/traces"
        exec {_prof_trace_fd}>"$_prof_state/traces/${0##*/}.${1:-}.$$.xtrace"
        BASH_XTRACEFD=$_prof_trace_fd
        PS4='+${EPOCHREALTIME}	${BASH_SOURCE[0]##*/}:${LINENO}	${FUNCNAME[0]:-}	'
        set -x
    fi
fi
