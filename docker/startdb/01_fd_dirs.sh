#!/bin/bash
# External tables write BADFILE/LOGFILE output here (DIRECTORY fd_log_dir).
# The data directory itself is mounted read-only, so logs need their own home.
mkdir -p /opt/oracle/oradata/fd_logs
