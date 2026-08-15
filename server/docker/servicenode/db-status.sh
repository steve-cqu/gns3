#!/bin/bash
# What is this PostgreSQL server actually doing?
# Usage: db-status.sh

PGDATA=/var/lib/postgresql/data
SOCKDIR=/run/postgresql

echo "================================================"
echo "PostgreSQL Server Status"
echo "================================================"
echo ""

echo "1. Server process:"
if su postgres -c "pg_ctl -D '$PGDATA' status" >/dev/null 2>&1; then
    su postgres -c "pg_ctl -D '$PGDATA' status" | sed 's/^/   /'
else
    echo "   PostgreSQL is NOT running — start it with start-db.sh"
fi
echo ""

echo "2. This node's addresses (what clients should point at):"
ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1' || echo "   no IPv4 address configured"
echo ""

echo "3. Is it accepting connections?"
su postgres -c "pg_isready -h '$SOCKDIR'" 2>&1 | sed 's/^/   /'
echo ""

echo "4. Who may connect (pg_hba.conf, non-comment lines):"
grep -vE '^\s*#|^\s*$' "$PGDATA/pg_hba.conf" 2>/dev/null | sed 's/^/   /' || echo "   not initialised yet"
echo ""

echo "5. Databases:"
su postgres -c "psql -h '$SOCKDIR' -c '\l'" 2>/dev/null | sed 's/^/   /' || echo "   query failed"
echo ""

echo "6. Rows in labdb.students (the seeded lab data):"
su postgres -c "psql -h '$SOCKDIR' -d labdb -c 'SELECT count(*) FROM students;'" 2>/dev/null | sed 's/^/   /' || echo "   labdb not present"
echo ""

echo "================================================"
echo "Data directory:   $PGDATA   (persisted)"
echo "Log file:         /var/lib/postgresql/logfile"
echo "================================================"
