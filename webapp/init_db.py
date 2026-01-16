#!/usr/bin/env python3
"""Initialize the SQLite database schema for crontab web UI."""

import sqlite3
import os
import sys


DB_PATH = '/opt/crontab/data/crontab.db'


def init_database():
    """Initialize database schema if not exists."""
    # Create data directory if it doesn't exist
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    # Create tables (idempotent - safe to run multiple times)
    cursor.executescript('''
        CREATE TABLE IF NOT EXISTS jobs (
            name TEXT PRIMARY KEY,
            schedule TEXT NOT NULL,
            command TEXT NOT NULL,
            image TEXT,
            container TEXT,
            comment TEXT,
            last_run TIMESTAMP,
            next_run TEXT,
            status TEXT DEFAULT 'scheduled',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS job_executions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            job_name TEXT NOT NULL,
            start_time TIMESTAMP NOT NULL,
            end_time TIMESTAMP,
            duration_seconds REAL,
            exit_code INTEGER,
            stdout_preview TEXT,
            stderr_preview TEXT,
            stdout_size INTEGER,
            stderr_size INTEGER,
            triggered_by TEXT DEFAULT 'cron',
            parent_job TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (job_name) REFERENCES jobs(name) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS system_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_type TEXT NOT NULL,
            message TEXT,
            metadata TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_executions_job_start
            ON job_executions(job_name, start_time DESC);
        CREATE INDEX IF NOT EXISTS idx_executions_start_time
            ON job_executions(start_time DESC);
        CREATE INDEX IF NOT EXISTS idx_events_type_time
            ON system_events(event_type, created_at DESC);
    ''')

    conn.commit()
    conn.close()
    print("✅ Database initialized successfully")
    return 0


if __name__ == '__main__':
    try:
        sys.exit(init_database())
    except Exception as e:
        print(f"❌ Error initializing database: {e}", file=sys.stderr)
        sys.exit(1)
