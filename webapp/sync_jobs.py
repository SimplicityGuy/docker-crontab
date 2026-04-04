#!/usr/bin/env python3
"""Sync jobs table from config.working.json."""

import sqlite3
import json
import sys
from cron_parser import CronParser


DB_PATH = '/opt/crontab/data/crontab.db'


def sync_jobs_from_config(config_path):
    """
    Sync jobs table from config.working.json.

    Args:
        config_path: Path to config.working.json

    Returns:
        int: 0 on success, 1 on error
    """
    try:
        with open(config_path, 'r') as f:
            jobs = json.load(f)

        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        parser = CronParser()

        # Get existing job names
        cursor.execute('SELECT name FROM jobs')
        existing_jobs = {row[0] for row in cursor.fetchall()}

        config_jobs = set()

        # Process each job from config
        for job in jobs:
            name = job.get('name', 'unnamed')
            config_jobs.add(name)

            # Calculate next run description
            schedule = job.get('schedule', '* * * * *')
            next_run = parser.parse_schedule(schedule)

            # Upsert job (insert or update)
            cursor.execute('''
                INSERT INTO jobs (name, schedule, command, image, container, comment, next_run)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(name) DO UPDATE SET
                    schedule = excluded.schedule,
                    command = excluded.command,
                    image = excluded.image,
                    container = excluded.container,
                    comment = excluded.comment,
                    next_run = excluded.next_run,
                    updated_at = CURRENT_TIMESTAMP
            ''', (
                name,
                schedule,
                job.get('command'),
                job.get('image'),
                job.get('container'),
                job.get('comment'),
                next_run
            ))

        # Remove jobs that no longer exist in config
        removed_jobs = existing_jobs - config_jobs
        for job_name in removed_jobs:
            cursor.execute('DELETE FROM jobs WHERE name = ?', (job_name,))

        conn.commit()
        conn.close()

        print(f"✅ Synced {len(config_jobs)} jobs to database")
        if removed_jobs:
            print(f"   Removed {len(removed_jobs)} stale jobs: {', '.join(removed_jobs)}")

        return 0

    except FileNotFoundError:
        print(f"❌ Error: Config file not found: {config_path}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as e:
        print(f"❌ Error parsing config JSON: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"❌ Error syncing jobs: {e}", file=sys.stderr)
        return 1


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: sync_jobs.py <config.working.json>", file=sys.stderr)
        sys.exit(1)

    sys.exit(sync_jobs_from_config(sys.argv[1]))
