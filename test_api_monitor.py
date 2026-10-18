import asyncio
import gzip
import json
from pathlib import Path
import tempfile
import unittest

from aiohttp import ClientSession, web
from api_monitor import create_app
from test_collector import complete


class ForwardingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'metrics.json'
        self.runners = []
        self.received = []
        self.stream_chunk_seen = asyncio.Event()
        self.response_number = 0
        upstream = web.Application(handler_args={'auto_decompress': False})
        upstream.router.add_route('*', '/backend-api/codex/{tail:.*}', self.upstream)
        self.upstream_url = await self.serve(upstream)
        self.proxy_url = await self.serve(create_app(self.path, self.upstream_url))
        self.client = ClientSession()

    async def asyncTearDown(self):
        await self.client.close()
        for runner in reversed(self.runners):
            await runner.cleanup()
        self.tmp.cleanup()

    async def serve(self, app):
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        self.runners.append(runner)
        site = web.TCPSite(runner, '127.0.0.1', 0)
        await site.start()
        return 'http://127.0.0.1:' + str(site._server.sockets[0].getsockname()[1])

    def snapshot(self):
        return json.loads(self.path.read_text())

    async def upstream(self, request):
        self.received.append((request.raw_path, request.headers.get('Authorization')))
        if request.headers.get('Upgrade', '').lower() == 'websocket':
            ws = web.WebSocketResponse()
            ws.headers['x-codex-turn-state'] = 'routing-state-test'
            await ws.prepare(request)
            async for msg in ws:
                value = json.loads(msg.data)
                self.response_number += 1
                rid = 'private-upstream-response-' + str(self.response_number)
                await ws.send_json({'type': 'response.created', 'response': {'id': rid}})
                if value.get('generate') is not False:
                    await ws.send_json({'type': 'response.custom_tool_call_input.delta',
                                        'response_id': rid, 'delta': 'secret'})
                await ws.send_json(complete(rid))
                await ws.send_json({'type': 'responsesapi.websocket_timing', 'response_id': rid,
                                    'timing_metrics': {'engine_service_total_ms': 450}})
            return ws
        self.received.append(await request.read())
        if request.path.endswith('/error'):
            return web.Response(status=429, body=b'upstream error', headers={'Retry-After': '2'})
        if request.path.endswith('/plain'):
            return web.Response(text='unchanged non-stream body')
        if request.query.get('json') == '1':
            return web.json_response(complete()['response'])
        encoded = request.query.get('encoded') == 'gzip'
        response_headers = {'Content-Type': {'binary': 'application/octet-stream', 'plain': 'text/plain'}.get(request.query.get('mime'), 'text/event-stream')}
        if encoded:
            response_headers['Content-Encoding'] = 'gzip'
        response = web.StreamResponse(headers=response_headers)
        await response.prepare(request)
        if encoded:
            body = b'data: ' + json.dumps(complete()).encode() + b'\n\n'
            await response.write(gzip.compress(body))
            return response
        await response.write(b': first chunk\n\n')
        await asyncio.wait_for(self.stream_chunk_seen.wait(), 2)
        payload = b'data: ' + json.dumps(complete()).encode() + b'\n\n'
        await response.write(payload[:17])
        await response.write(payload[17:])
        return response

    async def test_http_streams_without_full_response_buffering(self):
        async with self.client.post(self.proxy_url + '/backend-api/codex/responses?x=1',
                                    data=b'private request', headers={'Authorization': 'Bearer fake-test'}) as response:
            first = await response.content.readexactly(len(b': first chunk\n\n'))
            self.assertEqual(first, b': first chunk\n\n')
            self.stream_chunk_seen.set()
            self.assertEqual(await response.read(), b'data: ' + json.dumps(complete()).encode() + b'\n\n')
        self.assertEqual(self.received, [('/backend-api/codex/responses?x=1', 'Bearer fake-test'), b'private request'])
        self.assertEqual(self.snapshot()['last_completed']['output_tokens'], 120)
        for path in [self.path, *self.path.parent.glob('history-v3/*')]:
            text = path.read_text()
            self.assertNotIn('private request', text)
            self.assertNotIn('fake-test', text)
            self.assertNotIn('private-upstream', text)

    async def test_compressed_request_bytes_are_not_modified(self):
        self.stream_chunk_seen.set()
        body = gzip.compress(b'private compressed request')
        async with self.client.post(self.proxy_url + '/backend-api/codex/responses', data=body,
                                    headers={'Content-Encoding': 'gzip'}) as response:
            await response.read()
        self.assertEqual(self.received[-1], body)

    async def test_non_streaming_json_usage_is_measured_without_fake_ttft(self):
        async with self.client.post(self.proxy_url + '/backend-api/codex/responses?json=1') as response:
            self.assertEqual(await response.json(), complete()['response'])
        record = self.snapshot()['last_completed']
        self.assertEqual(record['output_tokens'], 120)
        self.assertEqual(record['response_format'], 'json')
        self.assertEqual(record['http_status'], 200)
        self.assertIsNone(record['first_output_seconds'])

    async def test_mislabelled_plain_text_sse_is_measured_from_framing(self):
        self.stream_chunk_seen.set()
        async with self.client.post(self.proxy_url + '/backend-api/codex/responses?mime=plain') as response:
            self.assertEqual(response.headers['Content-Type'], 'text/plain')
            await response.read()
        self.assertEqual(self.snapshot()['last_completed']['output_tokens'], 120)
        self.assertEqual(self.snapshot()['last_completed']['response_format'], 'sse')

    async def test_live_backend_octet_stream_sse_is_measured(self):
        self.stream_chunk_seen.set()
        async with self.client.post(self.proxy_url + '/backend-api/codex/responses?mime=binary') as response:
            self.assertEqual(response.headers['Content-Type'], 'application/octet-stream')
            await response.read()
        self.assertEqual(self.snapshot()['last_completed']['output_tokens'], 120)

    async def test_gzip_response_is_forwarded_unchanged_and_measured(self):
        async with ClientSession(auto_decompress=False) as client:
            async with client.post(self.proxy_url + '/backend-api/codex/responses?encoded=gzip') as response:
                body = await response.read()
                self.assertEqual(response.headers['Content-Encoding'], 'gzip')
        self.assertEqual(gzip.decompress(body), b'data: ' + json.dumps(complete()).encode() + b'\n\n')
        self.assertEqual(self.snapshot()['last_completed']['output_tokens'], 120)

    async def test_websocket_warmup_custom_tool_and_late_timing(self):
        async with self.client.ws_connect(self.proxy_url + '/backend-api/codex/responses',
                                         headers={'Authorization': 'Bearer fake-test'}) as ws:
            self.assertEqual(ws._response.headers['x-codex-turn-state'], 'routing-state-test')
            await ws.send_json({'type': 'response.create', 'generate': False})
            for _ in range(3):
                await ws.receive_json()
            self.assertIsNone(self.snapshot()['last_completed'])
            await ws.send_json({'type': 'response.create', 'model': 'unchanged'})
            self.assertEqual((await ws.receive_json())['type'], 'response.created')
            self.assertEqual((await ws.receive_json())['delta'], 'secret')
            await ws.receive_json()
            await ws.receive_json()
            await asyncio.sleep(.01)
            record = self.snapshot()['last_completed']
            self.assertEqual(record['output_tokens'], 120)
            self.assertIsNotNone(record['first_output_seconds'])
            self.assertEqual(record['engine_timing']['engine_service_total_ms'], 450)
            self.assertEqual(self.snapshot()['recent']['sample_count'], 1)
        self.assertNotIn('secret', self.path.read_text())

    async def test_errors_fixed_destination_and_versioned_health(self):
        async with self.client.post(self.proxy_url + '/backend-api/codex/error') as response:
            self.assertEqual(response.status, 429)
            self.assertEqual(response.headers['Retry-After'], '2')
            self.assertEqual(await response.read(), b'upstream error')
        async with self.client.get(self.proxy_url + '/anything-else') as response:
            self.assertEqual(response.status, 404)
        async with self.client.get(self.proxy_url + '/health') as response:
            self.assertEqual((await response.json())['version'], 3)


if __name__ == '__main__':
    unittest.main()
