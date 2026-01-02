// Docker Crontab Dashboard - Vanilla JavaScript Application

const App = {
    currentView: 'jobs',
    refreshInterval: null,
    refreshDelay: 30000, // 30 seconds

    /**
     * Initialize the application
     */
    init() {
        this.setupEventListeners();
        this.loadStats();
        this.loadJobs();
        this.startAutoRefresh();
        console.log('🚀 Dashboard initialized');
    },

    /**
     * Set up event listeners
     */
    setupEventListeners() {
        // Back to jobs button
        document.getElementById('back-to-jobs').addEventListener('click', () => {
            this.showJobsList();
        });

        // Refresh button
        document.getElementById('refresh-btn').addEventListener('click', () => {
            this.refresh();
        });

        // Modal close button
        document.getElementById('close-modal').addEventListener('click', () => {
            this.closeModal();
        });

        // Close modal on background click
        document.getElementById('log-modal').addEventListener('click', (e) => {
            if (e.target.id === 'log-modal') {
                this.closeModal();
            }
        });

        // Tab buttons
        document.querySelectorAll('.tab-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                this.switchTab(e.target.dataset.tab);
            });
        });

        // Keyboard shortcuts
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                this.closeModal();
            }
        });
    },

    /**
     * Start auto-refresh timer
     */
    startAutoRefresh() {
        this.refreshInterval = setInterval(() => {
            this.refresh();
        }, this.refreshDelay);
    },

    /**
     * Stop auto-refresh timer
     */
    stopAutoRefresh() {
        if (this.refreshInterval) {
            clearInterval(this.refreshInterval);
            this.refreshInterval = null;
        }
    },

    /**
     * Refresh current view
     */
    async refresh() {
        await this.loadStats();
        if (this.currentView === 'jobs') {
            await this.loadJobs();
        }
        console.log('🔄 Refreshed');
    },

    /**
     * Load dashboard statistics
     */
    async loadStats() {
        try {
            const resp = await fetch('/api/stats');
            const stats = await resp.json();

            document.getElementById('total-jobs').textContent = stats.total_jobs;
            document.getElementById('active-jobs').textContent = stats.active_jobs;
            document.getElementById('recent-failures').textContent = stats.recent_failures;
            document.getElementById('last-24h-executions').textContent = stats.last_24h_executions;
        } catch (error) {
            console.error('Error loading stats:', error);
        }
    },

    /**
     * Load all jobs
     */
    async loadJobs() {
        const container = document.getElementById('jobs-container');
        container.innerHTML = '<div class="loading">Loading jobs...</div>';

        try {
            const resp = await fetch('/api/jobs');
            const jobs = await resp.json();

            if (jobs.length === 0) {
                container.innerHTML = `
                    <div class="empty-state">
                        <h3>No Jobs Found</h3>
                        <p>No cron jobs are currently configured.</p>
                    </div>
                `;
                return;
            }

            container.innerHTML = jobs.map(job => this.renderJobCard(job)).join('');

            // Attach event listeners to job cards
            jobs.forEach(job => {
                const historyBtn = document.getElementById(`history-${job.name}`);
                const triggerBtn = document.getElementById(`trigger-${job.name}`);

                if (historyBtn) {
                    historyBtn.addEventListener('click', () => this.viewHistory(job.name));
                }

                if (triggerBtn) {
                    triggerBtn.addEventListener('click', () => this.triggerJob(job.name));
                }
            });

        } catch (error) {
            console.error('Error loading jobs:', error);
            container.innerHTML = `
                <div class="empty-state">
                    <h3>Error Loading Jobs</h3>
                    <p>${error.message}</p>
                </div>
            `;
        }
    },

    /**
     * Render a job card
     */
    renderJobCard(job) {
        const lastRun = job.last_run ? new Date(job.last_run).toLocaleString() : 'Never';
        const status = job.status || 'scheduled';

        return `
            <div class="job-card status-${status}">
                <div class="job-info">
                    <h3>${this.escapeHtml(job.name)}</h3>
                    <p>${this.escapeHtml(job.comment || job.command || 'No description')}</p>
                    <div class="job-meta">
                        <div class="job-meta-item">
                            <strong>Schedule</strong>
                            <span>${this.escapeHtml(job.schedule)}</span>
                        </div>
                        <div class="job-meta-item">
                            <strong>Next Run</strong>
                            <span>${this.escapeHtml(job.next_run || 'Calculating...')}</span>
                        </div>
                        <div class="job-meta-item">
                            <strong>Last Run</strong>
                            <span>${lastRun}</span>
                        </div>
                        <div class="job-meta-item">
                            <strong>Status</strong>
                            <span class="status-badge ${status === 'completed' ? 'success' : status === 'failed' ? 'failed' : ''}">${status}</span>
                        </div>
                    </div>
                </div>
                <div class="job-actions">
                    <button class="btn btn-primary" id="history-${this.escapeHtml(job.name)}">
                        📊 History
                    </button>
                    <button class="btn btn-success" id="trigger-${this.escapeHtml(job.name)}">
                        ▶️ Run Now
                    </button>
                </div>
            </div>
        `;
    },

    /**
     * View execution history for a job
     */
    async viewHistory(jobName) {
        this.currentView = 'history';
        document.getElementById('jobs-list').classList.add('hidden');
        document.getElementById('execution-history').classList.remove('hidden');
        document.getElementById('current-job-name').textContent = jobName;

        const container = document.getElementById('history-container');
        container.innerHTML = '<div class="loading">Loading history...</div>';

        try {
            const resp = await fetch(`/api/executions/${encodeURIComponent(jobName)}?limit=100`);
            const executions = await resp.json();

            if (executions.length === 0) {
                container.innerHTML = `
                    <div class="empty-state">
                        <h3>No Execution History</h3>
                        <p>This job hasn't been executed yet.</p>
                    </div>
                `;
                return;
            }

            container.innerHTML = `
                <div class="history-table">
                    <div class="history-header">
                        <div>Start Time</div>
                        <div>Duration</div>
                        <div>Exit Code</div>
                        <div>Triggered By</div>
                        <div>Actions</div>
                    </div>
                    ${executions.map(ex => this.renderExecutionRow(ex)).join('')}
                </div>
            `;

            // Attach event listeners to log buttons
            executions.forEach(ex => {
                const logBtn = document.getElementById(`logs-${ex.id}`);
                if (logBtn) {
                    logBtn.addEventListener('click', () => this.viewLogs(ex));
                }
            });

        } catch (error) {
            console.error('Error loading history:', error);
            container.innerHTML = `
                <div class="empty-state">
                    <h3>Error Loading History</h3>
                    <p>${error.message}</p>
                </div>
            `;
        }
    },

    /**
     * Render an execution row
     */
    renderExecutionRow(execution) {
        const startTime = new Date(execution.start_time).toLocaleString();
        const duration = execution.duration_seconds
            ? `${execution.duration_seconds.toFixed(2)}s`
            : 'In progress';
        const exitCode = execution.exit_code !== null ? execution.exit_code : '-';
        const statusClass = execution.exit_code === 0 ? 'success' : 'failed';

        return `
            <div class="execution-row">
                <div data-label="Start Time">${startTime}</div>
                <div data-label="Duration">${duration}</div>
                <div data-label="Exit Code">
                    <span class="status-badge ${statusClass}">
                        ${exitCode}
                    </span>
                </div>
                <div data-label="Triggered By">${this.escapeHtml(execution.triggered_by || 'cron')}</div>
                <div data-label="Actions">
                    <button class="btn btn-sm btn-primary" id="logs-${execution.id}">
                        📝 View Logs
                    </button>
                </div>
            </div>
        `;
    },

    /**
     * View logs for an execution
     */
    viewLogs(execution) {
        document.getElementById('log-job-name').textContent = execution.job_name;
        document.getElementById('log-start-time').textContent = new Date(execution.start_time).toLocaleString();
        document.getElementById('log-duration').textContent = execution.duration_seconds
            ? `${execution.duration_seconds.toFixed(2)}s`
            : 'In progress';
        document.getElementById('log-exit-code').textContent = execution.exit_code !== null
            ? execution.exit_code
            : '-';

        const stdout = execution.stdout_preview || '(empty)';
        const stderr = execution.stderr_preview || '(empty)';

        document.getElementById('log-stdout').textContent = stdout;
        document.getElementById('log-stderr').textContent = stderr;

        // Show stdout tab by default
        this.switchTab('stdout');

        // Show modal
        document.getElementById('log-modal').classList.remove('hidden');
    },

    /**
     * Close log modal
     */
    closeModal() {
        document.getElementById('log-modal').classList.add('hidden');
    },

    /**
     * Switch log tabs
     */
    switchTab(tabName) {
        // Update tab buttons
        document.querySelectorAll('.tab-btn').forEach(btn => {
            if (btn.dataset.tab === tabName) {
                btn.classList.add('active');
            } else {
                btn.classList.remove('active');
            }
        });

        // Update tab panes
        document.querySelectorAll('.log-pane').forEach(pane => {
            if (pane.id === `log-${tabName}`) {
                pane.classList.remove('hidden');
                pane.classList.add('active');
            } else {
                pane.classList.add('hidden');
                pane.classList.remove('active');
            }
        });
    },

    /**
     * Show jobs list
     */
    showJobsList() {
        this.currentView = 'jobs';
        document.getElementById('execution-history').classList.add('hidden');
        document.getElementById('jobs-list').classList.remove('hidden');
        this.loadJobs();
    },

    /**
     * Trigger a job manually
     */
    async triggerJob(jobName) {
        if (!confirm(`Trigger job "${jobName}" now?`)) {
            return;
        }

        try {
            const resp = await fetch(`/api/trigger/${encodeURIComponent(jobName)}`, {
                method: 'POST',
                headers: {
                    'X-Requested-With': 'XMLHttpRequest'
                }
            });

            const result = await resp.json();

            if (resp.ok) {
                alert(`✅ Job "${jobName}" triggered successfully!`);
                // Refresh jobs after a short delay
                setTimeout(() => this.loadJobs(), 1000);
            } else {
                alert(`❌ Error: ${result.error}`);
            }
        } catch (error) {
            alert(`❌ Error triggering job: ${error.message}`);
        }
    },

    /**
     * Escape HTML to prevent XSS
     */
    escapeHtml(text) {
        if (text === null || text === undefined) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
};

// Initialize app when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    App.init();
});
