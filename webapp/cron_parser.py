#!/usr/bin/env python3
"""Parse cron schedules and calculate next run times."""

import re
from datetime import datetime, timedelta


class CronParser:
    """Parser for cron schedule expressions."""

    # Shortcut mappings
    SHORTCUTS = {
        '@yearly': '0 0 1 1 *',
        '@annually': '0 0 1 1 *',
        '@monthly': '0 0 1 * *',
        '@weekly': '0 0 * * 0',
        '@daily': '0 0 * * *',
        '@midnight': '0 0 * * *',
        '@hourly': '0 * * * *',
    }

    def parse_schedule(self, schedule_str):
        """
        Parse crontab schedule and return human-readable next run time.

        Args:
            schedule_str: Cron schedule string (e.g., "*/5 * * * *", "@hourly")

        Returns:
            str: Human-readable description of next run time
        """
        schedule_str = schedule_str.strip()

        # Handle shortcuts
        if schedule_str in self.SHORTCUTS:
            schedule_str = self.SHORTCUTS[schedule_str]
            return self._describe_standard_cron(schedule_str)

        # Handle @every syntax
        if schedule_str.startswith('@every'):
            return self._parse_every(schedule_str)

        # Handle @random (return placeholder)
        if schedule_str.startswith('@random'):
            return "Random (varies per container start)"

        # Parse standard cron: minute hour day month weekday
        return self._describe_standard_cron(schedule_str)

    def _parse_every(self, schedule_str):
        """
        Parse @every syntax (e.g., @every 2m, @every 1h).

        Args:
            schedule_str: Schedule string starting with @every

        Returns:
            str: Description like "Every 2 minutes" or next execution time
        """
        # Extract duration: @every 2m, @every 1h30m, @every 1d
        match = re.search(r'@every\s+(\d+)([mhd])', schedule_str)
        if match:
            value, unit = int(match.group(1)), match.group(2)

            if unit == 'm':
                return f"Every {value} minute{'s' if value != 1 else ''}"
            elif unit == 'h':
                return f"Every {value} hour{'s' if value != 1 else ''}"
            elif unit == 'd':
                return f"Every {value} day{'s' if value != 1 else ''}"

        return "Invalid @every syntax"

    def _describe_standard_cron(self, schedule_str):
        """
        Convert standard cron syntax to human-readable description.

        Args:
            schedule_str: Standard cron string (e.g., "0 2 * * *")

        Returns:
            str: Human-readable description
        """
        parts = schedule_str.split()
        if len(parts) != 5:
            return f"Invalid cron syntax: {schedule_str}"

        minute, hour, day, month, weekday = parts

        # Handle common patterns
        if minute == '*' and hour == '*':
            return "Every minute"

        if minute.startswith('*/'):
            interval = minute[2:]
            return f"Every {interval} minute{'s' if int(interval) != 1 else ''}"

        if hour.startswith('*/') and minute == '0':
            interval = hour[2:]
            return f"Every {interval} hour{'s' if int(interval) != 1 else ''}"

        if day.startswith('*/') and minute == '0' and hour == '0':
            interval = day[2:]
            return f"Every {interval} day{'s' if int(interval) != 1 else ''}"

        # Specific time patterns
        if minute != '*' and hour != '*' and day == '*' and month == '*' and weekday == '*':
            return f"Daily at {hour.zfill(2)}:{minute.zfill(2)}"

        if minute != '*' and hour != '*' and day != '*' and month == '*' and weekday == '*':
            return f"Monthly on day {day} at {hour.zfill(2)}:{minute.zfill(2)}"

        # Fallback: show cron expression
        return f"Cron: {schedule_str}"

    def calculate_next_run(self, schedule_str, from_time=None):
        """
        Calculate next run time for a cron schedule.

        Args:
            schedule_str: Cron schedule string
            from_time: Reference time (default: now)

        Returns:
            datetime: Next execution time (approximate for complex patterns)
        """
        if from_time is None:
            from_time = datetime.now()

        # Handle @every syntax
        if schedule_str.startswith('@every'):
            match = re.search(r'@every\s+(\d+)([mhd])', schedule_str)
            if match:
                value, unit = int(match.group(1)), match.group(2)
                if unit == 'm':
                    return from_time + timedelta(minutes=value)
                elif unit == 'h':
                    return from_time + timedelta(hours=value)
                elif unit == 'd':
                    return from_time + timedelta(days=value)

        # Handle shortcuts
        if schedule_str in self.SHORTCUTS:
            schedule_str = self.SHORTCUTS[schedule_str]

        # Parse standard cron (simplified - just handle common patterns)
        parts = schedule_str.split()
        if len(parts) == 5:
            minute, hour, day, month, weekday = parts

            # Every N minutes
            if minute.startswith('*/'):
                interval = int(minute[2:])
                next_run = from_time + timedelta(minutes=interval)
                return next_run.replace(second=0, microsecond=0)

            # Every hour
            if hour.startswith('*/') and minute.isdigit():
                interval = int(hour[2:])
                next_run = from_time + timedelta(hours=interval)
                return next_run.replace(minute=int(minute), second=0, microsecond=0)

            # Specific time
            if minute.isdigit() and hour.isdigit():
                target_hour = int(hour)
                target_minute = int(minute)
                next_run = from_time.replace(hour=target_hour, minute=target_minute, second=0, microsecond=0)
                if next_run <= from_time:
                    next_run += timedelta(days=1)
                return next_run

        # Fallback: estimate ~1 hour from now
        return from_time + timedelta(hours=1)


if __name__ == '__main__':
    # Test the parser
    parser = CronParser()

    test_cases = [
        '*/5 * * * *',
        '0 2 * * *',
        '@hourly',
        '@every 2m',
        '@every 1h',
        '43 6,18 * * *',
        '* * * * *',
    ]

    print("Cron Parser Test Results:")
    print("-" * 60)
    for schedule in test_cases:
        description = parser.parse_schedule(schedule)
        print(f"{schedule:20} => {description}")
