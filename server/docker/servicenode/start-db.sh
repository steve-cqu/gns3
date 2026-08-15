#!/bin/bash
# Start the PostgreSQL database server on this node.
# Usage: start-db.sh
#
# On the very first run this initialises the database cluster, opens it to the network, and seeds a
# small `labdb` with a `students` table so backup and query labs have data on day one. On every run
# after that it just (re)starts the server, so the script is safe to run repeatedly and a student's
# data is never wiped by re-running it.

PGDATA=/var/lib/postgresql/data
LOG=/var/lib/postgresql/logfile
SOCKDIR=/run/postgresql

# The socket directory has to exist and be owned by postgres before the server starts.
mkdir -p "$SOCKDIR" "$PGDATA"
chown postgres:postgres "$SOCKDIR" "$PGDATA"

# First run only: create the cluster. PG_VERSION is present exactly when initdb has already run, so
# this block never touches an existing database.
FIRST_RUN=no
if [ ! -f "$PGDATA/PG_VERSION" ]; then
    FIRST_RUN=yes
    echo "First run: initialising the database cluster in $PGDATA ..."
    if ! su postgres -c "initdb -D '$PGDATA' -E UTF8 --locale=C --auth-local=peer --auth-host=scram-sha-256"; then
        echo "FAILED: initdb could not create the cluster. Nothing was started."
        exit 1
    fi
    # Open the server to the network. listen_addresses='*' is what lets another node reach it — and
    # is also the exposure the pg_hba.conf below controls. This is the teaching pair: the port is
    # open, but pg_hba decides who may actually authenticate.
    echo "listen_addresses = '*'" >> "$PGDATA/postgresql.conf"
    echo "logging_collector = off"  >> "$PGDATA/postgresql.conf"
    # Allow password logins from any address, using scram-sha-256 (never trust over the network).
    # Tighten this line to your lab subnet as the access-control exercise.
    echo "host    all    all    0.0.0.0/0    scram-sha-256" >> "$PGDATA/pg_hba.conf"
fi

# Restart cleanly if already running, so this script is safe to run repeatedly.
if su postgres -c "pg_ctl -D '$PGDATA' status" >/dev/null 2>&1; then
    echo "Stopping the running server..."
    su postgres -c "pg_ctl -D '$PGDATA' -m fast stop" >/dev/null 2>&1
    sleep 1
fi

echo "Starting PostgreSQL..."
su postgres -c "pg_ctl -D '$PGDATA' -l '$LOG' -o '-k $SOCKDIR' start"
sleep 2

if ! su postgres -c "pg_isready -h '$SOCKDIR'" >/dev/null 2>&1; then
    echo "PostgreSQL did not come up. Last lines of $LOG:"
    tail -n 15 "$LOG" 2>/dev/null | sed 's/^/   /'
    exit 1
fi

# First run only: seed a lab database and a login role. gns3 is the appliance's throwaway lab
# password — change it in a security exercise.
if [ "$FIRST_RUN" = yes ]; then
    echo "Seeding labdb (owner: student) ..."
    su postgres -c "psql -h '$SOCKDIR' -v ON_ERROR_STOP=1" <<'SQL'
CREATE ROLE student LOGIN PASSWORD 'gns3';
CREATE DATABASE labdb OWNER student;
\connect labdb
CREATE TABLE students (id serial PRIMARY KEY, name text, enrolled date);
INSERT INTO students (name, enrolled) VALUES
  ('Ada Lovelace','2026-03-01'),
  ('Alan Turing','2026-03-01'),
  ('Grace Hopper','2026-03-02');
-- student owns the table (not just SELECT/INSERT grants): a pg_dump taken as student then
-- restores cleanly as student. With postgres as owner, the dump's ALTER ... OWNER lines fail
-- with 'must be able to SET ROLE "postgres"' — found walking the backup/restore activity live.
ALTER TABLE students OWNER TO student;
SQL
fi

echo "PostgreSQL is running."
echo
echo "Connect on this node:        psql -h /run/postgresql -U postgres"
echo "Connect from another node:   psql -h <this-node-ip> -U student -d labdb   (password: gns3)"
echo "Back up the lab database:    pg_dump -h /run/postgresql -U postgres labdb > /root/labdb.sql"
echo "Check what it is doing:      db-status.sh"
