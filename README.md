# solr-monitor
Simple script to monitor Solr replication health


Dependencies: curl, xmllint, xmlstarlet.
Tested on Linux and OS X, Solr 4.1 API.

By default, it will check Solr cores in localhost on port 8983 and will have a replication tolerance of 15 minutes.
Meaning that if a slave core is behind the master and didn't replicate in 15 minutes, the script will return 2.

Return codes:

* 0, if everything is OK.
* 2, if we have a problem in a core (replication issues, core is down, Solr is not responding at all, returned an empty list of cores, etc)

Example usage:

```
$ ./solr-monitor -h
Usage:
    solr-monitor [OPTIONS]

Options:
    --help | -h
        Print the brief help message and exit.

    --man
        Print the manual page and exit.

    --host | -H HOST
        Check this host instead of localhost.

    --port | -P Port
        Use this port instead of the default(8983) to connect.

    --diff | -D Time difference in seconds between now and when solr last replicated
        Use this option to set the maximum difference in seconds between the
        time when the solr slave replicated and now.
```

```
$ ./solr-monitor --host solrmaster1
Core "core0" returned "OK".
Core "core1" returned "OK".
Core "core2" returned "OK".
$ echo $?
0

$ ./solr-monitor -H slave.solr.com -P 8080 --diff 3600
Core "slave0" is up to date.
Core "slave1" is up to date.
Core "slave2" could not get master index version.
Core "slave3" is up to date.
$ echo $?
2
```
