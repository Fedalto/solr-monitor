#!/bin/bash

# This script will get the list af active cores and issues a ping request to them.
# If a single request failes, the check will return ERROR
# All requests must return OK

# Local variables
EXIT_CODE=0
SOLR_HOST="localhost"
SOLR_HOST_PORT="8983"
# Last replication event must have been at least xxx sec ago.
REPLICATION_TIME_TOLERANCE=900 # = 15 min
OUT=""

set -u

parse_args() {
  # If no arguments are given
  if [ "$#" -eq 0 ]; then
    pod2usage "$0"
    exit 1
  fi

  # Parse arguments
  while [ $# -gt 0 ]
  do
    case "$1" in
      --help|-h|-\?)
        pod2usage -verbose 1 "$0"
        exit 1
      ;;

      --man)
        pod2usage -verbose 2 "$0"
        exit 1
      ;;

      --host|-H)
        SOLR_HOST="$2"
        shift 2
      ;;

      --port|-P)
        SOLR_HOST_PORT="$2"
        shift 2
      ;;

      --diff|-D)
        REPLICATION_TIME_TOLERANCE="$2"
        shift 2
      ;;

      *)
        # Non option argument
        break # Finish for loop
      ;;
    esac
  done

  # main code
  [ -n "$SOLR_HOST" ] || {
    echo "UNKNOWN: --host argument is not set"
    exit 2
  }
}

call_solr_api() {
  curl --retry 3 --max-time 15 --fail --silent "http://${SOLR_HOST}:${SOLR_HOST_PORT}/solr/${1}"

  if [ "$?" != "0" ]; then
    echo "CRITICAL: server \"$SOLR_HOST\" is not responding or returned incorrect data." >&2
    exit 2
  fi
}

get_cores_status() {
  call_solr_api "admin/cores"
}

get_replication_details() {
  call_solr_api "${1}/replication?command=details"
}

ping_solr_core() {
  call_solr_api "${1}/admin/ping"
}

get_solr_cores() {
  local response=$(<<< "$1" xmllint --format - | grep '<str name="name"'  | sed -e 's/[ ]*<str name="name">//g' -e 's/<\/str>//g')

  if [ -z "$response"  ]; then
    echo "CRITICAL: server \"$SOLR_HOST\" returned an empty list of cores."
    exit 2
  fi

  echo "$response"
}

is_master() {
  [[ $(xmlstarlet sel -t -v "/response/lst[@name='details']/str[@name='isMaster']" <<< "$1") == "true" ]]
}

check_init_failures() {
  local cores_status="$1"
  local cores_with_init_failures=$(xmlstarlet sel -t -m "/response/lst[@name='initFailures']/str" -m "@name" -v . -n <<< "${cores_status="$1"}" | grep -v '^$')
  for bad_core in $cores_with_init_failures; do
    local problem=$(xmlstarlet sel -t -v "/response/lst[@name='initFailures']/str[@name='$bad_core']" <<< "${cores_status="$1"}")
    OUT="${OUT}Core \"$bad_core\" could not initialize: ${problem}\n"
    EXIT_CODE=2
  done
}

check_master_core() {
  local core="$1"
  local result=$(ping_solr_core "$core")
  result=$(xmlstarlet sel -t -v "/response/str[@name='status']" <<< "$result")
  OUT="${OUT}Core \"${core}\" returned \"${result}\".\n"
  [ "$result" = "OK" ] || EXIT_CODE=2
}


check_slave_core() {
  local core="$1"
  local replication_details="$2"

  #Verifying replication health is harder, so there will be several checks.
  # 1) Check if master host is defined.
  # 2) Check indexReplicatedAtList and compare it with replicationFailedAtList. This will determine if replication is working.
  # 3) Check if indexReplicatedAtList is more then 2 hours behind now().  If it is then something might be wrong.
  # 4) Check if indexVersion on master and slave match.
  # Get the URL to the corresponding master core
  SOLR_SLAVE_MASTERURL=$(xmlstarlet sel -t -v "/response/lst[@name='details']/lst[@name='slave']/str[@name='masterUrl']" <<< "$replication_details")

  # Get the master index version
  SOLR_MASTER_INDEXVERSION=$(xmlstarlet sel -t -v "/response/lst[@name='details']/lst[@name='slave']/lst[@name='masterDetails']/long[@name='indexVersion']" <<< "$replication_details")

  # Get slave index version
  SOLR_SLAVE_INDEXVERSION=$(xmlstarlet sel -t -v "/response/lst[@name='details']/long[@name='indexVersion']" <<< "$replication_details")

  # Get the last time the core replicated correctly.
  SOLR_SLAVE_REPLICATEDAT=$(xmlstarlet sel -t -v "/response/lst[@name='details']/lst[@name='slave']/arr[@name='indexReplicatedAtList']/str[1]" <<< "$replication_details")

  # Get the last time the core failed to replicate.
  SOLR_SLAVE_FAILEDAT=$(xmlstarlet sel -t -v "/response/lst[@name='details']/lst[@name='slave']/arr[@name='replicationFailedAtList']/str[1]" <<< "$replication_details")

  # Is this core replicating (aka pulling index from master) right now?
  SOLR_SLAVE_REPLICATING=$(xmlstarlet sel -t -v "/response/lst[@name='details']/lst[@name='slave']/str[@name='isReplicating']" <<< "$replication_details")

  # masterUrl is not set, replication is broken.
  if [ -z "$SOLR_SLAVE_MASTERURL" ]; then
    OUT="$OUT\n"."Core \"${core}\" has no masterUrl set, solr.xml misconfiguration or orphaned core."
    EXIT_CODE=2
    continue
  fi

  # Slave could not get the master index version. Maybe the master is down or network issues.
  if [[ -z "$SOLR_MASTER_INDEXVERSION" ]]; then
    OUT="${OUT}Core \"$core\" could not get master index version.\n"
    EXIT_CODE=2
    continue
  fi

  # If SOLR_SLAVE_REPLICATEDAT is empty then the instance has not replicated once, this is an error.
  # Actually it's possible that this check will cause a false alert if the index is being replicated for the first time just now, so check for this also.
  if [ -z "$SOLR_SLAVE_FAILEDAT" -a -z "$SOLR_SLAVE_REPLICATEDAT" -a "$SOLR_SLAVE_REPLICATING" == "true" ]; then
    # Everything is ok, this is the first time this core has been triggered to replicate.
    OUT="${OUT}Core \"${core}\" is replicating for the first time.\n"
    continue
  fi

  if [ \( -n "$SOLR_SLAVE_FAILEDAT" -a -z "$SOLR_SLAVE_REPLICATEDAT" \) -o \( -z "$SOLR_SLAVE_FAILEDAT" -a -z "$SOLR_SLAVE_REPLICATEDAT" \) ]; then
    # This core has never replicated, this is an error.
    OUT="${OUT}Core \"${core}\" has problems replicating.\n"
    EXIT_CODE=2
    continue
  fi

  # We need to calculate if the last replication attempt was successfull.
  LAST_REPLICATION_SUCCESSFUL=`date -d "$SOLR_SLAVE_REPLICATEDAT" +%s`
  TOLERANCE=`date -d "now - $REPLICATION_TIME_TOLERANCE seconds" +%s`

  # Verify that either the timestamp is not older then REPLICATION_TIME_TOLERANCE seconds and if it is check that indexversions match.
  if [ $LAST_REPLICATION_SUCCESSFUL -gt $TOLERANCE -o $SOLR_MASTER_INDEXVERSION = $SOLR_SLAVE_INDEXVERSION ]; then
    # Everything is ok
    OUT="${OUT}Core \"${core}\" is up to date.\n"
  else
    # Slave if outdated.
    OUT="${OUT}Core \"${core}\" is behind master more then $REPLICATION_TIME_TOLERANCE seconds.\n"
    EXIT_CODE=2
  fi
}

main() {
  parse_args "$@"

  local cores_status=$(get_cores_status)

  local solr_cores=$(get_solr_cores "$cores_status")

  check_init_failures "$cores_status"

  for core in $solr_cores; do
    local replication_details=$(get_replication_details "$core")

    if is_master "$replication_details"; then
      check_master_core "$core"
    else
      check_slave_core "$core" "$replication_details"
    fi
  done

  echo -e -n "$OUT"
  exit $EXIT_CODE
}

main "$@"

__END__

=pod

=head1 NAME

solr-monitor - Simple script to check the status of all defined cores on a solr server

=head1 SYNOPSIS

solr-monitor [OPTIONS]

=head1 OPTIONS

=over 4

=item B<--help> | B<-h>

Print the brief help message and exit.

=item B<--man>

Print the manual page and exit.

=item B<--host> | B<-H> HOST

Check this host instead of localhost.

=item B<--port> | B<-P> Port

Use this port instead of the default(8983) to connect.

=item B<--diff> | B<-D> Time difference between now and when solr last replicated

Use this option to set the maximum difference in seconds between the time when the solr slave replicated and now.

=back

Use '--' to separate options and argument if it starts with '-'.

=head1 DESCRIPTION

Simple script to run that will query the solr server for a list of defined cores
and then verify that all of them respond to ping requests

=head1 EXAMPLES

  solr-monitor --host qa-c1-solrmst1

  solr-monitor -H qa-c1-solrmst1 -P 80 -D 900

=head1 AUTHOR

Alexander V. Chykysh <ochykysh@magus.org.ua>

Leonardo Fedalto <lfedalto@gmail.com>

=cut
