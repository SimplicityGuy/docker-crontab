#!/usr/bin/env python3
"""Flask web application for crontab dashboard."""

from flask import Flask, render_template, jsonify, request
import os
import subprocess
import re
from models import (
    get_all_jobs,
    get_job,
    get_job_executions,
    get_execution_by_id,
    get_dashboard_stats
)


app = Flask(__name__)
app.config['DATABASE'] = '/opt/crontab/data/crontab.db'


def validate_job_name(job_name):
    """
    Validate job name to prevent path traversal attacks.

    Args:
        job_name: Job name to validate

    Returns:
        str: Validated job name

    Raises:
        ValueError: If job name is invalid
    """
    if not re.match(r'^[a-zA-Z0-9_-]+$', job_name):
        raise ValueError("Invalid job name format")
    return job_name


@app.route('/')
def index():
    """Render the dashboard UI."""
    return render_template('index.html')


@app.route('/api/jobs')
def api_get_jobs():
    """
    Get all jobs with their current status.

    Returns:
        JSON list of jobs
    """
    try:
        jobs = get_all_jobs()
        return jsonify(jobs)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/api/jobs/<job_name>')
def api_get_job(job_name):
    """
    Get details for a specific job.

    Args:
        job_name: Name of the job

    Returns:
        JSON job object or 404
    """
    try:
        job_name = validate_job_name(job_name)
        job = get_job(job_name)
        if job:
            return jsonify(job)
        return jsonify({"error": "Job not found"}), 404
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/api/executions/<job_name>')
def api_get_executions(job_name):
    """
    Get execution history for a job.

    Args:
        job_name: Name of the job

    Query Parameters:
        limit: Maximum number of executions to return (default 50)

    Returns:
        JSON list of executions
    """
    try:
        job_name = validate_job_name(job_name)
        limit = request.args.get('limit', 50, type=int)
        limit = min(max(limit, 1), 1000)  # Clamp between 1 and 1000

        executions = get_job_executions(job_name, limit)
        return jsonify(executions)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/api/executions/id/<int:execution_id>')
def api_get_execution(execution_id):
    """
    Get details for a specific execution.

    Args:
        execution_id: Execution ID

    Returns:
        JSON execution object or 404
    """
    try:
        execution = get_execution_by_id(execution_id)
        if execution:
            return jsonify(execution)
        return jsonify({"error": "Execution not found"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/api/trigger/<job_name>', methods=['POST'])
def api_trigger_job(job_name):
    """
    Manually trigger a job execution.

    Args:
        job_name: Name of the job to trigger

    Returns:
        JSON status message
    """
    # Simple rate limiting (in-memory)
    if not hasattr(api_trigger_job, 'rate_limit'):
        api_trigger_job.rate_limit = {}

    import time
    now = time.time()
    job_triggers = api_trigger_job.rate_limit.get(job_name, [])
    job_triggers = [t for t in job_triggers if now - t < 60]  # Last minute

    if len(job_triggers) >= 5:
        return jsonify({"error": "Rate limit exceeded (max 5 triggers per minute)"}), 429

    try:
        job_name = validate_job_name(job_name)

        # Verify job exists
        job = get_job(job_name)
        if not job:
            return jsonify({"error": "Job not found"}), 404

        # Verify script exists
        script_path = f"/opt/crontab/jobs/{job_name}.sh"
        real_path = os.path.realpath(script_path)
        if not real_path.startswith('/opt/crontab/jobs/'):
            return jsonify({"error": "Invalid job path"}), 400

        if not os.path.exists(script_path):
            return jsonify({"error": "Job script not found"}), 404

        # Execute job in background
        subprocess.Popen(
            [script_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True
        )

        # Update rate limit
        job_triggers.append(now)
        api_trigger_job.rate_limit[job_name] = job_triggers

        return jsonify({
            "status": "triggered",
            "job": job_name,
            "timestamp": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        })

    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/api/stats')
def api_get_stats():
    """
    Get dashboard statistics.

    Returns:
        JSON stats object
    """
    try:
        stats = get_dashboard_stats()
        return jsonify(stats)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/api/health')
def api_health():
    """
    Health check endpoint.

    Returns:
        JSON health status
    """
    import time
    try:
        # Check database accessibility
        stats = get_dashboard_stats()
        db_ok = True
    except Exception:
        db_ok = False

    # Check if crond is running
    try:
        result = subprocess.run(
            ['ps', 'aux'],
            capture_output=True,
            text=True,
            timeout=2
        )
        crond_running = 'crond' in result.stdout
    except Exception:
        crond_running = False

    # Calculate uptime (approximate)
    try:
        with open('/proc/uptime', 'r') as f:
            uptime = float(f.read().split()[0])
    except Exception:
        uptime = 0

    status = "healthy" if (db_ok and crond_running) else "unhealthy"

    return jsonify({
        "status": status,
        "crond_running": crond_running,
        "database_accessible": db_ok,
        "uptime_seconds": int(uptime)
    }), 200 if status == "healthy" else 503


if __name__ == '__main__':
    # Run Flask server
    port = int(os.environ.get('WEB_UI_PORT', 8080))
    debug = os.environ.get('FLASK_ENV') == 'development'

    print(f"🚀 Starting web UI on port {port}")
    app.run(
        host='0.0.0.0',
        port=port,
        debug=debug,
        threaded=False
    )
