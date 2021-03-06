#!/bin/bash
#
# check_prometheus_metric.sh - nagios plugin wrapper for checking prometheus
#                              metrics - requires curl and jq to be in $PATH

# default configuration
CURL=curl
JQ=jq
COMPARISON_METHOD=ge
NAN_OK="false"

# nagios status codes
OK=0
WARNING=1
CRITICAL=2
UNKNOWN=3


function usage {

  cat <<'EoL'

  check_prometheus_metric.sh - simple prometheus metric extractor for nagios

  usage:
  check_prometheus_metric.sh -H HOST -q QUERY -w INT -c INT -n NAME [-m METHOD] [-O]

  options:
    -H HOST     URL of Prometheus host to query
    -q QUERY    Prometheus query that returns a float or int
    -w INT      Warning level value (must be zero or positive)
    -c INT      Critical level value (must be zero or positive)
    -n NAME     A name for the metric being checked
    -m METHOD   Comparison method, one of gt, ge, lt, le, eq, ne
                (defaults to ge unless otherwise specified)
    -O          Accept NaN as an "OK" result 

EoL
}


function process_command_line {

  while getopts ':H:q:w:c:m:n:O' OPT "$@"
  do
    case ${OPT} in
      H)        PROMETHEUS_SERVER="$OPTARG" ;;
      q)        PROMETHEUS_QUERY="$OPTARG" ;;
      n)        METRIC_NAME="$OPTARG" ;;

      m)        if [[ ${OPTARG} =~ ^([lg][et]|eq|ne)$ ]]
                then
                  COMPARISON_METHOD=${OPTARG}
                else
                  NAGIOS_SHORT_TEXT="invalid comparison method: ${OPTARG}"
                  NAGIOS_LONG_TEXT="$(usage)"
                  exit
                fi
                ;;

      c)        if [[ ${OPTARG} =~ ^[0-9]+$ ]]
                then
                  CRITICAL_LEVEL=${OPTARG}
                else
                  NAGIOS_SHORT_TEXT='-c CRITICAL_LEVEL requires an integer'
                  NAGIOS_LONG_TEXT="$(usage)"
                  exit
                fi
                ;;

      w)        if [[ ${OPTARG} =~ ^[0-9]+$ ]]
                then
                  WARNING_LEVEL=${OPTARG}
                else
                  NAGIOS_SHORT_TEXT='-w WARNING_LEVEL requires an integer'
                  NAGIOS_LONG_TEXT="$(usage)"
                  exit
                fi
                ;;

      O)        NAN_OK="true"
                ;;
        
      \?)       NAGIOS_SHORT_TEXT="invalid option: -$OPTARG"
                NAGIOS_LONG_TEXT="$(usage)"
                exit
                ;;

      \:)       NAGIOS_SHORT_TEXT="-$OPTARG requires an arguement"
                NAGIOS_LONG_TEXT="$(usage)"
                exit
                ;;
    esac
  done

  # check for missing parameters
  if [[ -z ${PROMETHEUS_SERVER} ]] ||
     [[ -z ${PROMETHEUS_QUERY} ]] ||
     [[ -z ${METRIC_NAME} ]] ||
     [[ -z ${WARNING_LEVEL} ]] ||
     [[ -z ${CRITICAL_LEVEL} ]]
  then
    NAGIOS_SHORT_TEXT='missing required option'
    NAGIOS_LONG_TEXT="$(usage)"
    exit
  fi
}


function on_exit {

  if [[ -z ${NAGIOS_STATUS} ]]
  then
    NAGIOS_STATUS=UNKNOWN
  fi

  if [[ -z ${NAGIOS_SHORT_TEXT} ]]
  then
    NAGIOS_SHORT_TEXT='an unknown error occured'
  fi

  printf '%s - %s\n' ${NAGIOS_STATUS} "${NAGIOS_SHORT_TEXT}"

  if [[ -n ${NAGIOS_LONG_TEXT} ]]
  then
    printf '%s\n' "${NAGIOS_LONG_TEXT}"
  fi

  exit ${!NAGIOS_STATUS} # hint: an indirect variable reference
}


function get_prometheus_result {

  local _RESULT

  _RESULT=$( ${CURL} -sgG --data-urlencode "query=${PROMETHEUS_QUERY}" "${PROMETHEUS_SERVER}/api/v1/query" | $JQ -r '.data.result[0].value[1]' )

  # check result
  if [[ ${_RESULT} =~ ^-?[0-9]+\.?[0-9]*$ ]]
  then
    printf '%.0F' ${_RESULT} # return an int if result is a number
  else
    case "${_RESULT}" in
      +Inf) printf '%.0F' $(( ${WARNING_LEVEL} + ${CRITICAL_LEVEL} )) # something greater than either level
            ;;
      -Inf) printf -- '-1' # something smaller than any level
            ;;
      *)    printf '%s' "${_RESULT}" # otherwise return as a string
            ;;
    esac
  fi
}

# set up exit function
trap on_exit EXIT TERM

# process the cli options
process_command_line "$@"

# get the metric value from prometheus
PROMETHEUS_RESULT="$( get_prometheus_result )"

# check the value
if [[ ${PROMETHEUS_RESULT} =~ ^-?[0-9]+$ ]]
then
  if eval [[ ${PROMETHEUS_RESULT} -${COMPARISON_METHOD} ${CRITICAL_LEVEL} ]]
  then
    NAGIOS_STATUS=CRITICAL
    NAGIOS_SHORT_TEXT="${METRIC_NAME} is ${PROMETHEUS_RESULT}"
  elif eval [[ ${PROMETHEUS_RESULT} -${COMPARISON_METHOD} $WARNING_LEVEL ]]
  then
    NAGIOS_STATUS=WARNING
    NAGIOS_SHORT_TEXT="${METRIC_NAME} is ${PROMETHEUS_RESULT}"
  else
    NAGIOS_STATUS=OK
    NAGIOS_SHORT_TEXT="${METRIC_NAME} is ${PROMETHEUS_RESULT}"
  fi
else
  if [[ "${NAN_OK}" = "true" && "${PROMETHEUS_RESULT}" = "NaN" ]]
  then
    NAGIOS_STATUS=OK
    NAGIOS_SHORT_TEXT="${METRIC_NAME} is ${PROMETHEUS_RESULT}"
  else    
    NAGIOS_SHORT_TEXT="unable to parse prometheus response"
    NAGIOS_LONG_TEXT="${METRIC_NAME} is ${PROMETHEUS_RESULT}"
  fi
fi

exit
