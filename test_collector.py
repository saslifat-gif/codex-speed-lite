import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from collector import Store, StreamTracker
from api_monitor import SSE, BodyObserver


def complete(rid='private-upstream-id', tokens=120, reasoning=80):
    return {'type': 'response.completed', 'response': {
        'id': rid, 'status': 'completed', 'usage': {
            'output_tokens': tokens, 'output_tokens_details': {'reasoning_tokens': reasoning}}}}


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'api-metrics.json'
        self.store = Store(self.path)
        self.wall = time.time() - 20

    def begin(self):
        sample = self.store.begin()
        sample.start = 100
        sample.started_at = self.wall
        return sample

    def snapshot(self):
        return self.store.snapshot(now=self.wall + 20)

    def test_rate_custom_tool_and_payload_privacy(self):
        sample = self.begin()
        sample.consume({'type': 'response.custom_tool_call_input.delta', 'delta': 'private code'}, at=101)
        sample.consume(complete(), at=104)
        data = self.snapshot()
        self.assertEqual(data['recent']['throughput_tps'], 30)
        self.assertEqual(data['last_completed']['first_output_seconds'], 1)
        self.assertEqual(data['last_completed']['reasoning_tokens'], 80)
        for path in [self.path, *self.store.history.glob('*')]:
            text = path.read_text()
            self.assertNotIn('private code', text)
            self.assertNotIn('private-upstream-id', text)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_completed_survives_next_start_and_parallel_requests(self):
        older = self.begin()
        newer = self.begin()
        older.consume(complete('old', 100, 0), at=102)
        self.assertEqual(self.snapshot()['last_completed']['output_tokens'], 100)
        self.assertEqual(self.snapshot()['active_requests'], 1)
        newer.consume(complete('new', 300, 0), at=106)
        self.store.begin()
        data = self.snapshot()
        self.assertEqual(data['recent']['sample_count'], 2)
        self.assertEqual(data['recent']['throughput_tps'], 50)  # 400 / (2 + 6), NOT mean(50, 50).
        self.assertEqual(data['last_completed']['output_tokens'], 300)
        self.assertEqual(json.loads(self.path.read_text())['last_completed']['output_tokens'], 300)

    def test_duration_weighted_average_and_window_expiry(self):
        a = self.begin()
        a.consume(complete('a', 100, 0), at=102)
        b = self.begin()
        b.consume(complete('b', 120, 0), at=106)
        data = self.snapshot()
        self.assertAlmostEqual(data['recent']['throughput_tps'], 27.5)  # 220 / 8, not (50 + 20) / 2.
        expired = self.store.snapshot(now=self.wall + 100)
        self.assertEqual(expired['recent']['sample_count'], 0)
        self.assertIsNone(expired['recent']['throughput_tps'])
        self.assertEqual(expired['last_completed']['output_tokens'], 120)

    def test_late_engine_timing_updates_same_request_without_double_counting(self):
        sample = self.begin()
        sample.consume({'type': 'response.created', 'response': {'id': 'rid'}}, at=100)
        sample.consume(complete('rid'), at=104)
        timing = {'type': 'responsesapi.websocket_timing', 'response_id': 'rid',
                  'timing_metrics': {'engine_service_total_ms': 450, 'engine_service_ttft_total_ms': 50,
                                     'private_unsupported_field': 'secret'}}
        sample.consume(timing, at=105)
        data = self.snapshot()
        self.assertEqual(data['recent']['sample_count'], 1)
        self.assertEqual(data['last_completed']['engine_timing']['engine_service_total_ms'], 450)
        self.assertEqual(data['last_completed']['revision'], 2)
        restored = Store(self.path)
        recovered = restored.snapshot(now=self.wall + 20)
        self.assertEqual(recovered['recent']['sample_count'], 1)
        self.assertEqual(recovered['last_completed']['engine_timing']['engine_service_total_ms'], 450)
        self.assertNotIn('secret', self.path.read_text())

    def test_missing_usage_has_explicit_reason_without_erasing_last_sample(self):
        good = self.begin()
        good.consume(complete(), at=102)
        bad = self.begin()
        bad.consume({'type': 'response.completed', 'response': {'usage': None}}, at=103)
        snap = self.snapshot()
        self.assertEqual(snap['last_issue']['reason'], 'missing_usage')
        self.assertEqual(snap['last_completed']['output_tokens'], 120)
        self.assertEqual(snap['recent']['sample_count'], 1)

    def test_receipt_timestamp_not_later_processing_time(self):
        sample = self.begin()
        # Completion received at 103.31; downstream forwarding/processing ends much later.
        with patch('collector.time.monotonic', return_value=999):
            sample.consume({'type': 'response.output_text.delta', 'delta': 'x'}, at=102.86)
            sample.consume(complete(tokens=21, reasoning=0), at=103.31)
        record = self.snapshot()['last_completed']
        self.assertAlmostEqual(record['request_seconds'], 3.31)
        self.assertAlmostEqual(record['first_output_seconds'], 2.86)
        self.assertNotIn('generation_tps', record)

    def test_bounded_sse_split_lines_and_event_header(self):
        sample = self.begin()
        parser = SSE(sample)
        payload = complete()
        del payload['type']
        body = ('event: response.completed\r\ndata: ' + json.dumps(payload) + '\r\n\r\n').encode()
        for byte in body:
            parser.feed(bytes([byte]), at=104)
        self.assertEqual(self.snapshot()['last_completed']['output_tokens'], 120)
        oversized = self.begin()
        SSE(oversized).feed(b'data: ' + b'x' * (5 * 1024 * 1024), at=104)
        self.assertEqual(self.snapshot()['last_issue']['reason'], 'oversize_event')

    def test_response_encoding_and_unknown_usage_are_not_guessed(self):
        sample = self.begin()
        with patch('collector.time.monotonic', return_value=102):
            BodyObserver(sample, 'zstd')
        self.assertEqual(self.snapshot()['last_issue']['reason'], 'unsupported_content_encoding')
        invalid = self.begin()
        invalid.consume(complete(tokens=True, reasoning=0), at=104)
        self.assertEqual(self.snapshot()['last_issue']['reason'], 'invalid_usage')
        self.assertIsNone(self.snapshot()['recent']['throughput_tps'])

    def test_body_observer_uses_framing_without_a_separate_parser_mode(self):
        sample = self.begin()
        observer = BodyObserver(sample, 'identity')
        observer.feed(json.dumps(complete()['response']).encode(), at=104)
        observer.end()
        record = self.snapshot()['last_completed']
        self.assertIsNotNone(record, 'A valid JSON usage response must be measured without an opt-in parser mode')
        self.assertEqual(record['output_tokens'], 120)

    def test_snapshot_window_boundaries_exclude_old_and_future_completions(self):
        for rid, tokens, finish in [('boundary', 200, 104), ('old', 100, 102), ('future', 300, 180)]:
            sample = self.begin()
            sample.consume(complete(rid, tokens, 0), at=finish)
        summary = self.store.snapshot(now=self.wall + 64)['recent']
        self.assertEqual(summary['sample_count'], 1)
        self.assertEqual(summary['output_tokens'], 200)
        self.assertEqual(summary['request_seconds'], 4)
        self.assertEqual(summary['throughput_tps'], 50)

    def test_failed_storage_does_not_raise_into_forwarder(self):
        sample = self.begin()
        with patch('collector.os.open', side_effect=OSError('synthetic failure')):
            sample.consume(complete(), at=104)
        self.assertFalse(self.store.storage_ok)
        self.assertEqual(self.snapshot()['recent']['sample_count'], 1)


class StreamCorrelationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Store(Path(self.tmp.name) / 'metrics.json')
        self.tracker = StreamTracker(self.store)

    def test_warmup_is_excluded_and_other_connection_cannot_overwrite(self):
        self.tracker.outgoing({'type': 'response.create', 'generate': False})
        self.tracker.incoming({'type': 'response.created', 'response': {'id': 'warmup'}})
        self.tracker.incoming(complete('warmup'))
        self.assertEqual(len(self.store.records), 0)
        self.tracker.outgoing({'type': 'response.create'})
        self.tracker.incoming({'type': 'response.created', 'response': {'id': 'a'}})
        other = StreamTracker(self.store)
        other.outgoing({'type': 'response.create'})
        other.incoming({'type': 'response.created', 'response': {'id': 'b'}})
        self.tracker.incoming(complete('a'))
        other.incoming(complete('b'))
        self.assertEqual(len(self.store.records), 2)
        self.assertEqual(len(self.store.active), 0)

    def test_two_bound_responses_can_complete_out_of_order(self):
        for rid in ('a', 'b'):
            self.tracker.outgoing({'type': 'response.create'})
            self.tracker.incoming({'type': 'response.created', 'response': {'id': rid}})
        self.tracker.incoming(complete('b', 300, 0))
        self.tracker.incoming(complete('a', 100, 0))
        self.assertEqual(sorted(r['output_tokens'] for r in self.store.records.values()), [100, 300])
        self.tracker.incoming({'type': 'responsesapi.websocket_timing', 'response_id': 'b',
                               'timing_metrics': {'engine_service_total_ms': 700}})
        matched = [r for r in self.store.records.values() if r['output_tokens'] == 300][0]
        self.assertEqual(matched['engine_timing']['engine_service_total_ms'], 700)

    def test_unmatched_timing_and_ambiguous_responses_are_not_assigned(self):
        self.tracker.outgoing({'type': 'response.create'})
        self.tracker.outgoing({'type': 'response.create'})
        self.tracker.incoming(complete('unknown'))
        self.assertEqual({r['reason'] for r in self.store.records.values()}, {'ambiguous_stream_correlation'})
        self.assertTrue(all(r['output_tokens'] is None for r in self.store.records.values()))
        self.tracker.incoming({'type': 'responsesapi.websocket_timing',
                               'timing_metrics': {'engine_service_total_ms': 300}})
        self.assertEqual(self.store.diagnostics['uncorrelated_server_timing'], 1)

    def test_disconnect_keeps_prior_success_and_records_incomplete_request(self):
        self.tracker.outgoing({'type': 'response.create'})
        self.tracker.incoming(complete('a'))
        self.tracker.outgoing({'type': 'response.create'})
        self.tracker.close()
        records = list(self.store.records.values())
        self.assertEqual([r['status'] for r in records], ['completed', 'cancelled'])
        self.assertEqual(records[-1]['reason'], 'client_disconnected')


if __name__ == '__main__':
    unittest.main()
