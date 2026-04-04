// Docker Crontab Dashboard - Vanilla JavaScript Application
// All dynamic text is escaped via escapeHtml() before DOM insertion to prevent XSS.

const App = {
    currentView: 'jobs',
    refreshInterval: null,
    refreshDelay: 30000, // 30 seconds

    init() {
        this.setupEventListeners();
        this.loadStats();
        this.loadJobs();
        this.checkHealth();
        this.startAutoRefresh();
    },

    setupEventListeners() {
        document.getElementById('back-to-jobs').addEventListener('click', () => {
            this.showJobsList();
        });

        document.getElementById('refresh-btn').addEventListener('click', () => {
            this.refresh();
        });

        document.getElementById('close-modal').addEventListener('click', () => {
            this.closeModal();
        });

        document.getElementById('modal-backdrop').addEventListener('click', () => {
            this.closeModal();
        });

        document.querySelectorAll('.tab-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                this.switchTab(e.target.dataset.tab);
            });
        });

        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                this.closeModal();
            }
        });
    },

    startAutoRefresh() {
        this.refreshInterval = setInterval(() => {
            this.refresh();
        }, this.refreshDelay);
    },

    async refresh() {
        await Promise.all([this.loadStats(), this.checkHealth()]);
        if (this.currentView === 'jobs') {
            await this.loadJobs();
        }
    },

    async checkHealth() {
        const indicator = document.getElementById('health-indicator');
        try {
            const resp = await fetch('/api/health');
            const data = await resp.json();
            if (data.status === 'healthy') {
                indicator.textContent = '';
                indicator.className = 'flex items-center gap-1.5 text-xs text-emerald-600';
                const dot = document.createElement('span');
                dot.className = 'relative flex h-2 w-2';
                dot.innerHTML = '<span class="animate-pulse-dot absolute inline-flex h-full w-full rounded-full bg-emerald-400"></span><span class="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span>';
                const label = document.createElement('span');
                label.textContent = 'Healthy';
                indicator.appendChild(dot);
                indicator.appendChild(label);
            } else {
                indicator.textContent = '';
                indicator.className = 'flex items-center gap-1.5 text-xs text-red-600';
                const dot = document.createElement('span');
                dot.className = 'relative flex h-2 w-2';
                const inner = document.createElement('span');
                inner.className = 'relative inline-flex rounded-full h-2 w-2 bg-red-500';
                dot.appendChild(inner);
                const label = document.createElement('span');
                label.textContent = 'Unhealthy';
                indicator.appendChild(dot);
                indicator.appendChild(label);
            }
        } catch {
            indicator.textContent = '';
            indicator.className = 'flex items-center gap-1.5 text-xs text-gray-500';
            const dot = document.createElement('span');
            dot.className = 'relative flex h-2 w-2';
            const inner = document.createElement('span');
            inner.className = 'relative inline-flex rounded-full h-2 w-2 bg-gray-400';
            dot.appendChild(inner);
            const label = document.createElement('span');
            label.textContent = 'Offline';
            indicator.appendChild(dot);
            indicator.appendChild(label);
        }
    },

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

    async loadJobs() {
        const container = document.getElementById('jobs-container');

        try {
            const resp = await fetch('/api/jobs');
            const jobs = await resp.json();

            if (jobs.length === 0) {
                container.textContent = '';
                const empty = this._createEmptyState(
                    'M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z',
                    'No jobs found',
                    'No cron jobs are currently configured.'
                );
                container.appendChild(empty);
                return;
            }

            container.textContent = '';
            const wrapper = document.createElement('div');
            wrapper.className = 'space-y-3';
            jobs.forEach(job => {
                wrapper.appendChild(this.buildJobCard(job));
            });
            container.appendChild(wrapper);

        } catch (error) {
            console.error('Error loading jobs:', error);
            container.textContent = '';
            const errState = this._createEmptyState(
                'M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.732-.833-2.5 0L4.268 16.5c-.77.833.192 2.5 1.732 2.5z',
                'Error loading jobs',
                error.message,
                'text-red-300'
            );
            container.appendChild(errState);
        }
    },

    _createEmptyState(iconPath, title, description, iconColor) {
        const div = document.createElement('div');
        div.className = 'text-center py-16';

        const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('class', `mx-auto w-12 h-12 ${iconColor || 'text-gray-300'} mb-4`);
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('viewBox', '0 0 24 24');
        const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
        path.setAttribute('stroke-linecap', 'round');
        path.setAttribute('stroke-linejoin', 'round');
        path.setAttribute('stroke-width', '1.5');
        path.setAttribute('d', iconPath);
        svg.appendChild(path);
        div.appendChild(svg);

        const h3 = document.createElement('h3');
        h3.className = 'text-sm font-semibold text-gray-900';
        h3.textContent = title;
        div.appendChild(h3);

        const p = document.createElement('p');
        p.className = 'mt-1 text-sm text-gray-500';
        p.textContent = description;
        div.appendChild(p);

        return div;
    },

    _svgIcon(pathD, cls) {
        const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('class', cls);
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('viewBox', '0 0 24 24');
        const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
        p.setAttribute('stroke-linecap', 'round');
        p.setAttribute('stroke-linejoin', 'round');
        p.setAttribute('stroke-width', '2');
        p.setAttribute('d', pathD);
        svg.appendChild(p);
        return svg;
    },

    buildJobCard(job) {
        const lastRun = job.last_run ? new Date(job.last_run).toLocaleString() : 'Never';
        const status = job.status || 'scheduled';

        const statusConfig = {
            running:   { border: 'border-l-blue-500',    badge: 'bg-blue-100 text-blue-700',       dot: 'bg-blue-500' },
            completed: { border: 'border-l-emerald-500', badge: 'bg-emerald-100 text-emerald-700', dot: 'bg-emerald-500' },
            failed:    { border: 'border-l-red-500',     badge: 'bg-red-100 text-red-700',         dot: 'bg-red-500' },
            scheduled: { border: 'border-l-gray-300',    badge: 'bg-gray-100 text-gray-600',       dot: 'bg-gray-400' },
        };
        const sc = statusConfig[status] || statusConfig.scheduled;

        const card = document.createElement('div');
        card.className = `bg-white rounded-xl border border-gray-200 border-l-4 ${sc.border} p-5 hover:shadow-md transition-shadow animate-fade-in`;

        const row = document.createElement('div');
        row.className = 'flex flex-col sm:flex-row sm:items-center justify-between gap-4';

        // Info section
        const info = document.createElement('div');
        info.className = 'flex-1 min-w-0';

        // Title row
        const titleRow = document.createElement('div');
        titleRow.className = 'flex items-center gap-2.5 mb-1.5';

        const h3 = document.createElement('h3');
        h3.className = 'text-base font-semibold text-gray-900 truncate';
        h3.textContent = job.name;
        titleRow.appendChild(h3);

        const badge = document.createElement('span');
        badge.className = `inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${sc.badge}`;
        const dot = document.createElement('span');
        dot.className = `w-1.5 h-1.5 rounded-full ${sc.dot}`;
        badge.appendChild(dot);
        badge.appendChild(document.createTextNode(status));
        titleRow.appendChild(badge);

        info.appendChild(titleRow);

        const desc = document.createElement('p');
        desc.className = 'text-sm text-gray-500 truncate mb-3';
        desc.textContent = job.comment || job.command || 'No description';
        info.appendChild(desc);

        // Meta row
        const meta = document.createElement('div');
        meta.className = 'flex flex-wrap gap-x-5 gap-y-1 text-xs';

        const addMeta = (label, value, mono) => {
            const d = document.createElement('div');
            const lbl = document.createElement('span');
            lbl.className = 'font-medium text-gray-400 uppercase tracking-wider';
            lbl.textContent = label;
            const val = document.createElement('span');
            val.className = `ml-1.5 text-gray-700${mono ? ' font-mono' : ''}`;
            val.textContent = value;
            d.appendChild(lbl);
            d.appendChild(val);
            meta.appendChild(d);
        };

        addMeta('Schedule', job.schedule, true);
        addMeta('Next', job.next_run || 'Calculating...', false);
        addMeta('Last Run', lastRun, false);
        info.appendChild(meta);

        // Actions
        const actions = document.createElement('div');
        actions.className = 'flex items-center gap-2 shrink-0';

        const historyBtn = document.createElement('button');
        historyBtn.className = 'inline-flex items-center gap-1.5 px-3 py-2 text-sm font-medium text-indigo-700 bg-indigo-50 rounded-lg hover:bg-indigo-100 transition-colors';
        historyBtn.appendChild(this._svgIcon('M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z', 'w-4 h-4'));
        historyBtn.appendChild(document.createTextNode(' History'));
        historyBtn.addEventListener('click', () => this.viewHistory(job.name));
        actions.appendChild(historyBtn);

        const triggerBtn = document.createElement('button');
        triggerBtn.className = 'inline-flex items-center gap-1.5 px-3 py-2 text-sm font-medium text-white bg-emerald-600 rounded-lg hover:bg-emerald-700 transition-colors';
        triggerBtn.appendChild(this._svgIcon('M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z', 'w-4 h-4'));
        triggerBtn.appendChild(document.createTextNode(' Run Now'));
        triggerBtn.addEventListener('click', () => this.triggerJob(job.name));
        actions.appendChild(triggerBtn);

        row.appendChild(info);
        row.appendChild(actions);
        card.appendChild(row);

        return card;
    },

    async viewHistory(jobName) {
        this.currentView = 'history';
        document.getElementById('jobs-list').classList.add('hidden');
        document.getElementById('execution-history').classList.remove('hidden');
        document.getElementById('current-job-name').textContent = jobName;

        const container = document.getElementById('history-container');
        container.textContent = '';
        const loading = document.createElement('div');
        loading.className = 'flex items-center justify-center py-16 text-gray-400';
        loading.textContent = 'Loading history...';
        container.appendChild(loading);

        try {
            const resp = await fetch(`/api/executions/${encodeURIComponent(jobName)}?limit=100`);
            const executions = await resp.json();

            container.textContent = '';

            if (executions.length === 0) {
                const empty = this._createEmptyState(
                    'M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10',
                    'No execution history',
                    'This job hasn\'t been executed yet.'
                );
                container.appendChild(empty);
                return;
            }

            const table = document.createElement('div');
            table.className = 'bg-white rounded-xl border border-gray-200 overflow-hidden animate-fade-in';

            // Header
            const header = document.createElement('div');
            header.className = 'hidden sm:grid grid-cols-[2fr_1fr_100px_120px_120px] gap-4 px-5 py-3 bg-gray-50 border-b border-gray-200';
            ['Start Time', 'Duration', 'Exit Code', 'Trigger', 'Actions'].forEach(text => {
                const col = document.createElement('div');
                col.className = 'text-xs font-semibold text-gray-500 uppercase tracking-wider';
                col.textContent = text;
                header.appendChild(col);
            });
            table.appendChild(header);

            const body = document.createElement('div');
            body.className = 'divide-y divide-gray-100';

            executions.forEach(ex => {
                body.appendChild(this.buildExecutionRow(ex));
            });

            table.appendChild(body);
            container.appendChild(table);

        } catch (error) {
            console.error('Error loading history:', error);
            container.textContent = '';
            const errState = this._createEmptyState(
                'M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.732-.833-2.5 0L4.268 16.5c-.77.833.192 2.5 1.732 2.5z',
                'Error loading history',
                error.message,
                'text-red-300'
            );
            container.appendChild(errState);
        }
    },

    buildExecutionRow(execution) {
        const startTime = new Date(execution.start_time).toLocaleString();
        const duration = execution.duration_seconds
            ? `${execution.duration_seconds.toFixed(2)}s`
            : 'In progress';
        const exitCode = execution.exit_code !== null ? String(execution.exit_code) : '-';
        const isSuccess = execution.exit_code === 0;
        const badgeClass = isSuccess
            ? 'bg-emerald-100 text-emerald-700'
            : 'bg-red-100 text-red-700';

        const row = document.createElement('div');
        row.className = 'grid grid-cols-1 sm:grid-cols-[2fr_1fr_100px_120px_120px] gap-2 sm:gap-4 px-5 py-3.5 items-center hover:bg-gray-50 transition-colors';

        const col1 = document.createElement('div');
        col1.className = 'text-sm text-gray-900';
        col1.textContent = startTime;

        const col2 = document.createElement('div');
        col2.className = 'text-sm text-gray-600 font-mono';
        col2.textContent = duration;

        const col3 = document.createElement('div');
        const badgeEl = document.createElement('span');
        badgeEl.className = `inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold ${badgeClass}`;
        badgeEl.textContent = exitCode;
        col3.appendChild(badgeEl);

        const col4 = document.createElement('div');
        col4.className = 'text-sm text-gray-500';
        col4.textContent = execution.triggered_by || 'cron';

        const col5 = document.createElement('div');
        const logBtn = document.createElement('button');
        logBtn.className = 'inline-flex items-center gap-1 px-2.5 py-1.5 text-xs font-medium text-indigo-700 bg-indigo-50 rounded-lg hover:bg-indigo-100 transition-colors';
        logBtn.appendChild(this._svgIcon('M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z', 'w-3.5 h-3.5'));
        logBtn.appendChild(document.createTextNode(' Logs'));
        logBtn.addEventListener('click', () => this.viewLogs(execution));
        col5.appendChild(logBtn);

        row.appendChild(col1);
        row.appendChild(col2);
        row.appendChild(col3);
        row.appendChild(col4);
        row.appendChild(col5);

        return row;
    },

    viewLogs(execution) {
        document.getElementById('log-job-name').textContent = execution.job_name;
        document.getElementById('log-start-time').textContent = new Date(execution.start_time).toLocaleString();
        document.getElementById('log-duration').textContent = execution.duration_seconds
            ? `${execution.duration_seconds.toFixed(2)}s`
            : 'In progress';
        document.getElementById('log-exit-code').textContent = execution.exit_code !== null
            ? execution.exit_code
            : '-';

        document.getElementById('log-stdout').textContent = execution.stdout_preview || '(empty)';
        document.getElementById('log-stderr').textContent = execution.stderr_preview || '(empty)';

        this.switchTab('stdout');
        document.getElementById('log-modal').classList.remove('hidden');
    },

    closeModal() {
        document.getElementById('log-modal').classList.add('hidden');
    },

    switchTab(tabName) {
        document.querySelectorAll('.tab-btn').forEach(btn => {
            if (btn.dataset.tab === tabName) {
                btn.className = 'tab-btn px-4 py-2 text-sm font-medium border-b-2 transition-colors text-indigo-600 border-indigo-600';
            } else {
                btn.className = 'tab-btn px-4 py-2 text-sm font-medium border-b-2 transition-colors text-gray-500 border-transparent hover:text-gray-700';
            }
        });

        document.querySelectorAll('.log-pane').forEach(pane => {
            if (pane.id === `log-${tabName}`) {
                pane.classList.remove('hidden');
            } else {
                pane.classList.add('hidden');
            }
        });
    },

    showJobsList() {
        this.currentView = 'jobs';
        document.getElementById('execution-history').classList.add('hidden');
        document.getElementById('jobs-list').classList.remove('hidden');
        this.loadJobs();
    },

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
                this.showToast(`Job "${jobName}" triggered successfully`, 'success');
                setTimeout(() => this.loadJobs(), 1000);
            } else {
                this.showToast(`Error: ${result.error}`, 'error');
            }
        } catch (error) {
            this.showToast(`Error triggering job: ${error.message}`, 'error');
        }
    },

    showToast(message, type) {
        const existing = document.getElementById('toast');
        if (existing) existing.remove();

        const colors = type === 'success'
            ? 'bg-emerald-600 text-white'
            : 'bg-red-600 text-white';

        const toast = document.createElement('div');
        toast.id = 'toast';
        toast.className = `fixed bottom-6 right-6 z-50 px-4 py-3 rounded-xl shadow-lg text-sm font-medium ${colors} animate-fade-in`;
        toast.textContent = message;
        document.body.appendChild(toast);

        setTimeout(() => {
            toast.style.transition = 'opacity 0.3s';
            toast.style.opacity = '0';
            setTimeout(() => toast.remove(), 300);
        }, 3000);
    },

    escapeHtml(text) {
        if (text === null || text === undefined) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
};

document.addEventListener('DOMContentLoaded', () => {
    App.init();
});
