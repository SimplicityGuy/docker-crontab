#!/usr/bin/env python3
"""Database models and query functions."""

import sqlite3
from typing import List, Dict, Optional
from datetime import datetime, timedelta


DB_PATH = '/opt/crontab/data/crontab.db'


def get_db():
    """Get database connection with row factory."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def get_all_jobs() -> List[Dict]:
    """
    Get all jobs with their status.

    Returns:
        List of job dictionaries
    """
    db = get_db()
    cursor = db.execute('''
        SELECT * FROM jobs ORDER BY name
    ''')
    jobs = [dict(row) for row in cursor.fetchall()]
    db.close()
    return jobs


def get_job(job_name: str) -> Optional[Dict]:
    """
    Get a single job by name.

    Args:
        job_name: Name of the job

    Returns:
        Job dictionary or None if not found
    """
    db = get_db()
    cursor = db.execute('''
        SELECT * FROM jobs WHERE name = ?
    ''', (job_name,))
    row = cursor.fetchone()
    db.close()
    return dict(row) if row else None


def get_job_executions(job_name: str, limit: int = 50) -> List[Dict]:
    """
    Get execution history for a job.

    Args:
        job_name: Name of the job
        limit: Maximum number of executions to return

    Returns:
        List of execution dictionaries
    """
    db = get_db()
    cursor = db.execute('''
        SELECT * FROM job_executions
        WHERE job_name = ?
        ORDER BY start_time DESC
        LIMIT ?
    ''', (job_name, limit))
    executions = [dict(row) for row in cursor.fetchall()]
    db.close()
    return executions


def get_execution_by_id(execution_id: int) -> Optional[Dict]:
    """
    Get a single execution by ID.

    Args:
        execution_id: Execution ID

    Returns:
        Execution dictionary or None if not found
    """
    db = get_db()
    cursor = db.execute('''
        SELECT * FROM job_executions WHERE id = ?
    ''', (execution_id,))
    row = cursor.fetchone()
    db.close()
    return dict(row) if row else None


def get_dashboard_stats() -> Dict:
    """
    Get dashboard statistics.

    Returns:
        Dictionary with stats
    """
    db = get_db()

    # Total jobs
    cursor = db.execute('SELECT COUNT(*) as count FROM jobs')
    total_jobs = cursor.fetchone()['count']

    # Active jobs (not failed)
    cursor = db.execute('''
        SELECT COUNT(*) as count FROM jobs WHERE status != 'failed'
    ''')
    active_jobs = cursor.fetchone()['count']

    # Total executions
    cursor = db.execute('SELECT COUNT(*) as count FROM job_executions')
    total_executions = cursor.fetchone()['count']

    # Recent failures (last 24 hours)
    yesterday = (datetime.now() - timedelta(days=1)).isoformat()
    cursor = db.execute('''
        SELECT COUNT(*) as count FROM job_executions
        WHERE exit_code != 0 AND start_time > ?
    ''', (yesterday,))
    recent_failures = cursor.fetchone()['count']

    # Executions in last 24 hours
    cursor = db.execute('''
        SELECT COUNT(*) as count FROM job_executions
        WHERE start_time > ?
    ''', (yesterday,))
    last_24h_executions = cursor.fetchone()['count']

    db.close()

    return {
        'total_jobs': total_jobs,
        'active_jobs': active_jobs,
        'total_executions': total_executions,
        'recent_failures': recent_failures,
        'last_24h_executions': last_24h_executions
    }


def cleanup_old_executions(retention_days: int = 30, retention_count: int = 1000):
    """
    Clean up old job executions based on retention policy.

    Args:
        retention_days: Keep executions newer than this many days
        retention_count: Keep at least this many recent executions
    """
    db = get_db()

    # Delete executions that are:
    # 1. Not in the most recent N executions AND
    # 2. Older than retention_days
    cutoff_date = (datetime.now() - timedelta(days=retention_days)).isoformat()

    db.execute('''
        DELETE FROM job_executions
        WHERE id NOT IN (
            SELECT id FROM job_executions
            ORDER BY start_time DESC LIMIT ?
        ) AND start_time < ?
    ''', (retention_count, cutoff_date))

    deleted = db.total_changes
    db.commit()
    db.close()

    if deleted > 0:
        print(f"✅ Cleaned up {deleted} old job executions")

    return deleted


if __name__ == '__main__':
    # Test database queries
    print("Testing database models...")
    print("-" * 60)

    try:
        stats = get_dashboard_stats()
        print(f"Dashboard Stats: {stats}")

        jobs = get_all_jobs()
        print(f"\nFound {len(jobs)} jobs")
        for job in jobs:
            print(f"  - {job['name']}: {job['schedule']}")

    except Exception as e:
        print(f"Error: {e}")
