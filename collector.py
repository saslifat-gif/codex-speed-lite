"""Metadata-only per-request measurements; no prompts, text, or upstream IDs on disk."""
from collections import Counter, OrderedDict
from datetime import datetime, timedelta
import json
import math
import os
from pathlib import Path
import tempfile
import time
import uuid

SCHEMA = 3
WINDOW = 60
OUTPUT_EVENTS = {
    'response.output_text.delta', 'response.reasoning_text.delta',
    'response.reasoning_summary_text.delta', 'response.function_call_arguments.delta',
    'response.custom_tool_call_input.delta',
}
ENGINE_FIELDS = {
    'engine_service_total_ms', 'engine_service_ttft_total_ms',
    'engine_iapi_ttft_total_ms', 'engine_iapi_tbt_across_engine_calls_ms',
    'engine_service_tbt_across_engine_calls_ms',
    'responses_duration_excl_engine_and_client_tool_time_ms',
}
REASONS = {
    'missing_usage', 'invalid_usage', 'incomplete_response', 'api_error',
    'stream_ended_before_usage', 'client_disconnected', 'upstream_connection_failed',
    'upstream_http_error', 'unsupported_content_encoding', 'non_streaming_response',
    'oversize_event', 'malformed_event', 'ambiguous_stream_correlation',
    'uncorrelated_server_timing', 'unmatched_response', 'request_limit_exceeded',
}
RECORD_FIELDS = {
    'sample_id', 'status', 'reason', 'started_at', 'finished_at', 'request_seconds',
    'first_output_seconds', 'last_output_seconds', 'output_events', 'output_tokens',
    'reasoning_tokens', 'engine_timing', 'revision', 'http_status', 'response_format',
}


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def response_id(value):
    if not isinstance(value, dict):
        return None
    response = value.get('response')
    result = value.get('response_id') or (response.get('id') if isinstance(response, dict) else None)
    return result if isinstance(result, str) and 0 < len(result) <= 512 else None


def valid_record(record):
    """Validate even our own journal before using recovered numerical samples."""
    if not isinstance(record, dict) or set(record) - RECORD_FIELDS:
        return False
    sid = record.get('sample_id')
    if not isinstance(sid, str) or len(sid) != 32 or any(c not in '0123456789abcdef' for c in sid):
        return False
    if record.get('status') not in ('completed', 'unavailable', 'failed', 'cancelled', 'incomplete'):
        return False
    if record.get('reason') is not None and record['reason'] not in REASONS:
        return False
    for key in ('started_at', 'finished_at', 'request_seconds', 'output_events', 'revision'):
        if not number(record.get(key)):
            return False
    if record['request_seconds'] <= 0 or record['finished_at'] < record['started_at']:
        return False
    for key in ('first_output_seconds', 'last_output_seconds', 'output_tokens', 'reasoning_tokens'):
        if record.get(key) is not None and not number(record[key]):
            return False
    if record.get('http_status') is not None and (type(record['http_status']) is not int or not 100 <= record['http_status'] <= 599):
        return False
    if record.get('response_format') not in (None, 'sse', 'json', 'octet', 'html', 'other', 'websocket'):
        return False
    engine = record.get('engine_timing', {})
    if not isinstance(engine, dict) or set(engine) - ENGINE_FIELDS:
        return False
    if not all(number(v) for v in engine.values()):
        return False
    return record.get('status') != 'completed' or type(record.get('output_tokens')) is int


class Store:
    def __init__(self, path, window=WINDOW):
        self.path = Path(path)
        self.history = self.path.parent / 'history-v3'
        self.started = time.time()
        self.window = window
        self.active = {}
        self.records = OrderedDict()
        self.diagnostics = Counter()
        self.storage_ok = True
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.history.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.recover()
        except OSError:
            self.storage_ok = False
        self.publish()

    def recover(self):
        today = datetime.now().astimezone().date()
        for date in (today - timedelta(days=1), today):
            path = self.history / (date.isoformat() + '.jsonl')
            if not path.exists() or path.stat().st_size > 64 * 1024 * 1024:
                continue
            with path.open() as stream:
                for line in stream:
                    if len(line) > 16384:
                        continue
                    try:
                        record = json.loads(line)
                    except ValueError:
                        continue
                    if valid_record(record):
                        old = self.records.get(record['sample_id'])
                        if old is None or record['revision'] > old['revision']:
                            self.records[record['sample_id']] = record

    def begin(self):
        sample = Sample(self)
        self.active[sample.local_id] = sample
        self.publish()
        return sample

    def diagnose(self, reason):
        if reason in REASONS:
            self.diagnostics[reason] += 1
            self.publish()

    def commit(self, record):
        if not valid_record(record):
            return
        self.active.pop(record['sample_id'], None)
        self.records[record['sample_id']] = record
        while len(self.records) > 20000:
            self.records.popitem(last=False)
        # Append terminal records plus keyed revisions for late engine timing.
        # Revisions are upserts on recovery, never extra usage samples.
        try:
            date = datetime.fromtimestamp(record['finished_at']).astimezone().date().isoformat()
            path = self.history / (date + '.jsonl')
            flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0)
            fd = os.open(path, flags, 0o600)
            with os.fdopen(fd, 'a') as stream:
                stream.write(json.dumps(record, separators=(',', ':')) + '\n')
        except OSError:
            self.storage_ok = False
        self.publish()

    def snapshot(self, now=None):
        now = time.time() if now is None else now
        completed = [r for r in self.records.values() if r['status'] == 'completed']
        recent = [r for r in completed if now - self.window <= r['finished_at'] <= now]
        last = max(completed, key=lambda r: r['finished_at'], default=None)
        issues = [r for r in self.records.values() if r['status'] != 'completed']
        issue = max(issues, key=lambda r: r['finished_at'], default=None)
        duration = sum(r['request_seconds'] for r in recent)
        tokens = sum(r['output_tokens'] for r in recent)
        return {
            'schema_version': SCHEMA, 'updated_at': now, 'collector_started_at': self.started,
            'storage_ok': self.storage_ok, 'active_requests': len(self.active),
            'last_completed': last, 'last_issue': issue,
            'recent': {
                'window_seconds': self.window, 'sample_count': len(recent),
                'output_tokens': tokens, 'request_seconds': duration,
                'throughput_tps': tokens / duration if duration > 0 else None,
            },
            'diagnostic_counts': dict(self.diagnostics),
        }

    def publish(self):
        temp = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', dir=self.path.parent, prefix='.api-metrics-', delete=False) as stream:
                temp = stream.name
                json.dump(self.snapshot(), stream, separators=(',', ':'))
            os.replace(temp, self.path)
        except OSError:
            self.storage_ok = False
            if temp:
                try:
                    os.unlink(temp)
                except OSError:
                    pass


class Sample:
    def __init__(self, store):
        self.store = store
        self.local_id = uuid.uuid4().hex
        self.start = time.monotonic()
        self.started_at = time.time()
        self.upstream_id = None  # Memory only; never stored in a snapshot or journal.
        self.first = None
        self.last = None
        self.output_events = 0
        self.done = False
        self.engine = {}
        self.record = None
        self.http_status = None
        self.response_format = None

    def consume(self, value, at=None):
        if not isinstance(value, dict):
            return
        at = time.monotonic() if at is None else at
        kind = value.get('type', '')
        rid = response_id(value)
        if self.upstream_id and rid and rid != self.upstream_id:
            self.store.diagnose('unmatched_response')
            return
        # Timing can arrive after response.completed. Only accept explicit correlation.
        if kind == 'responsesapi.websocket_timing':
            if not rid or not self.upstream_id or rid != self.upstream_id:
                self.store.diagnose('uncorrelated_server_timing')
                return
            timing = value.get('timing_metrics')
            if isinstance(timing, dict):
                self.engine.update({k: v for k, v in timing.items() if k in ENGINE_FIELDS and number(v)})
                if self.record:
                    self.record = dict(self.record, engine_timing=dict(self.engine), revision=self.record['revision'] + 1)
                    self.store.commit(self.record)
            return
        if rid and not self.upstream_id:
            self.upstream_id = rid
        if self.done:
            return
        if kind in OUTPUT_EVENTS and isinstance(value.get('delta'), str) and value['delta']:
            elapsed = max(at - self.start, 0)
            if self.first is None:
                self.first = elapsed
            self.last = elapsed
            self.output_events += 1
        if kind in ('response.failed', 'error'):
            self.finish('failed', 'api_error', at)
        elif kind == 'response.incomplete':
            self.finish('incomplete', 'incomplete_response', at)
        elif kind == 'response.completed':
            response = value.get('response')
            usage = response.get('usage') if isinstance(response, dict) else None
            if not isinstance(usage, dict) or 'output_tokens' not in usage:
                self.finish('unavailable', 'missing_usage', at)
                return
            tokens = usage['output_tokens']
            details = usage.get('output_tokens_details') or {}
            reasoning = details.get('reasoning_tokens') if isinstance(details, dict) else None
            if type(tokens) is not int or tokens < 0 or (reasoning is not None and (type(reasoning) is not int or not 0 <= reasoning <= tokens)):
                self.finish('unavailable', 'invalid_usage', at)
                return
            if response.get('status') not in (None, 'completed'):
                self.finish('incomplete', 'incomplete_response', at)
                return
            self.finish('completed', None, at, tokens, reasoning)

    def finish(self, status='cancelled', reason='stream_ended_before_usage', at=None, tokens=None, reasoning=None):
        if self.done:
            return
        self.done = True
        at = time.monotonic() if at is None else at
        duration = max(at - self.start, 0.000001)
        self.record = {
            'sample_id': self.local_id, 'status': status,
            'reason': reason if reason in REASONS else None,
            'started_at': self.started_at, 'finished_at': self.started_at + duration,
            'request_seconds': duration, 'first_output_seconds': self.first,
            'last_output_seconds': self.last, 'output_events': self.output_events,
            'output_tokens': tokens, 'reasoning_tokens': reasoning,
            'engine_timing': dict(self.engine), 'revision': 1,
            'http_status': self.http_status, 'response_format': self.response_format,
        }
        self.store.commit(self.record)


class Slot:
    def __init__(self, sample):
        self.sample = sample
        self.done = False
        self.ended = None


class StreamTracker:
    """Correlate each socket separately; never guess across concurrent responses."""
    def __init__(self, store):
        self.store = store
        self.pending = []
        self.bound = OrderedDict()

    def outgoing(self, value):
        if not isinstance(value, dict) or value.get('type') != 'response.create':
            return
        self.prune()
        if len(self.pending) >= 32:
            self.store.diagnose('request_limit_exceeded')
            self.close('ambiguous_stream_correlation')
            return
        sample = None if value.get('generate') is False else self.store.begin()
        if sample:
            sample.http_status = 101
            sample.response_format = 'websocket'
        self.pending.append(Slot(sample))

    def prune(self):
        now = time.monotonic()
        for rid, slot in list(self.bound.items()):
            if slot.done and slot.ended is not None and now - slot.ended > 120:
                del self.bound[rid]
        # Keep late-timing correlation bounded on a long-lived connection.
        if len(self.bound) > 1024:
            for rid, slot in list(self.bound.items()):
                if slot.done:
                    del self.bound[rid]
                if len(self.bound) <= 1024:
                    break

    def incoming(self, value, at=None):
        if not isinstance(value, dict):
            self.store.diagnose('malformed_event')
            return
        at = time.monotonic() if at is None else at
        kind = value.get('type', '')
        rid = response_id(value)
        slot = self.bound.get(rid) if rid else None
        if kind == 'responsesapi.websocket_timing':
            if slot is not None and slot.sample is not None:
                slot.sample.consume(value, at)
            elif slot is None:
                self.store.diagnose('uncorrelated_server_timing')
            return
        if rid and slot is None:
            if len(self.pending) == 1:
                slot = self.pending.pop()
                self.bound[rid] = slot
                if slot.sample:
                    slot.sample.upstream_id = rid
            elif len(self.pending) > 1:
                self.close('ambiguous_stream_correlation')
                return
        if slot is None and not rid:
            candidates = self.pending + [s for s in self.bound.values() if not s.done]
            if len(candidates) == 1:
                slot = candidates[0]
            elif len(candidates) > 1:
                self.close('ambiguous_stream_correlation')
                return
        if slot is None:
            if kind.startswith('response.'):
                self.store.diagnose('unmatched_response')
            return
        if slot.sample:
            slot.sample.consume(value, at)
        if kind in ('response.completed', 'response.incomplete', 'response.failed', 'error'):
            slot.done = True
            slot.ended = at
            if slot in self.pending:
                self.pending.remove(slot)
        self.prune()

    def close(self, reason='client_disconnected'):
        slots = list(self.pending) + list(self.bound.values())
        for slot in slots:
            if slot.sample and not slot.done:
                status = 'unavailable' if reason == 'ambiguous_stream_correlation' else 'cancelled'
                slot.sample.finish(status, reason)
            slot.done = True
            slot.ended = time.monotonic()
        self.pending.clear()
        self.bound.clear()
