#!/usr/bin/env python3
"""Database logging helper called by job scripts to record executions."""

import sqlite3
import sys
from datetime import datetime


DB_PATH = '/opt/crontab/data/crontab.db'
MAX_PREVIEW_SIZE = 10 * 1024  # 10KB preview


def truncate_output(content, max_size=MAX_PREVIEW_SIZE):
    """Truncate output to max size, preserving size information."""
    if len(content) > max_size:
        return content[:max_size] + f"\n... (truncated, {len(content)} bytes total)"
    return content


def log_start(job_name, start_time, triggered_by, pid):
    """
    Log the start of a job execution.

    Args:
        job_name: Name of the job
        start_time: ISO 8601 timestamp
        triggered_by: 'cron' or 'manual'
        pid: Process ID
    """
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()

        cursor.execute('''
            INSERT INTO job_executions (job_name, start_time, triggered_by)
            VALUES (?, ?, ?)
        ''', (job_name, start_time, triggered_by))

        execution_id = cursor.lastrowid

        # Update job status to 'running'
        cursor.execute('''
            UPDATE jobs SET status = 'running', last_run = ? WHERE name = ?
        ''', (start_time, job_name))

        conn.commit()
        conn.close()

        # Print execution ID so script can use it
        print(f"EXECUTION_ID={execution_id}", file=sys.stderr)
        return 0

    except Exception as e:
        print(f"Error logging job start: {e}", file=sys.stderr)
        return 1


def log_end(job_name, end_time, exit_code, stdout_file, stderr_file):
    """
    Log the completion of a job execution.

    Args:
        job_name: Name of the job
        end_time: ISO 8601 timestamp
        exit_code: Exit code from command
        stdout_file: Path to stdout temp file
        stderr_file: Path to stderr temp file
    """
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()

        # Read output files
        stdout_content = ""
        stderr_content = ""
        stdout_size = 0
        stderr_size = 0

        try:
            with open(stdout_file, 'r', encoding='utf-8', errors='replace') as f:
                stdout_content = f.read()
                stdout_size = len(stdout_content)
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f"Warning: Could not read stdout file: {e}", file=sys.stderr)

        try:
            with open(stderr_file, 'r', encoding='utf-8', errors='replace') as f:
                stderr_content = f.read()
                stderr_size = len(stderr_content)
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f"Warning: Could not read stderr file: {e}", file=sys.stderr)

        # Truncate for preview
        stdout_preview = truncate_output(stdout_content)
        stderr_preview = truncate_output(stderr_content)

        # Find the most recent execution for this job that hasn't ended
        cursor.execute('''
            SELECT id, start_time FROM job_executions
            WHERE job_name = ? AND end_time IS NULL
            ORDER BY start_time DESC LIMIT 1
        ''', (job_name,))

        row = cursor.fetchone()
        if row:
            execution_id, start_time = row

            # Calculate duration
            start_dt = datetime.fromisoformat(start_time.replace('Z', '+00:00'))
            end_dt = datetime.fromisoformat(end_time.replace('Z', '+00:00'))
            duration = (end_dt - start_dt).total_seconds()

            # Update execution record
            cursor.execute('''
                UPDATE job_executions
                SET end_time = ?,
                    duration_seconds = ?,
                    exit_code = ?,
                    stdout_preview = ?,
                    stderr_preview = ?,
                    stdout_size = ?,
                    stderr_size = ?
                WHERE id = ?
            ''', (end_time, duration, exit_code, stdout_preview, stderr_preview,
                  stdout_size, stderr_size, execution_id))

            # Update job status based on exit code
            status = 'completed' if exit_code == 0 else 'failed'
            cursor.execute('''
                UPDATE jobs SET status = ? WHERE name = ?
            ''', (status, job_name))

            conn.commit()
            conn.close()
            return 0
        else:
            print(f"Warning: No pending execution found for {job_name}", file=sys.stderr)
            conn.close()
            return 1

    except Exception as e:
        print(f"Error logging job end: {e}", file=sys.stderr)
        return 1


def main():
    """Main entry point for db_logger script."""
    if len(sys.argv) < 3:
        print("Usage: db_logger.py <start|end> <job_name> ...", file=sys.stderr)
        print("  start <job_name> <timestamp> <triggered_by> <pid>", file=sys.stderr)
        print("  end <job_name> <timestamp> <exit_code> <stdout_file> <stderr_file>", file=sys.stderr)
        return 1

    command = sys.argv[1]

    if command == 'start':
        if len(sys.argv) != 6:
            print("Usage: db_logger.py start <job_name> <timestamp> <triggered_by> <pid>", file=sys.stderr)
            return 1
        return log_start(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])

    elif command == 'end':
        if len(sys.argv) != 7:
            print("Usage: db_logger.py end <job_name> <timestamp> <exit_code> <stdout_file> <stderr_file>", file=sys.stderr)
            return 1
        return log_end(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6])

    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
