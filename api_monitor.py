#!/usr/bin/env python3
"""Loopback streaming relay. Forwards unchanged payloads; persists metadata only."""
import asyncio
import contextlib
import json
import logging
from pathlib import Path
import time
import zlib

from aiohttp import ClientSession, ClientTimeout, WSMsgType, web
from collector import SCHEMA, Store, StreamTracker

STATE = Path.home() / '.local/share/codex-speed-lite/api-metrics.json'
PORT = 47831
CLIENT = web.AppKey('client', ClientSession)
HOP = {'host', 'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
       'te', 'trailer', 'transfer-encoding', 'upgrade', 'content-length'}
LIMIT = 4 * 1024 * 1024


def decode(data):
    try:
        return json.loads(data)
    except (ValueError, UnicodeDecodeError):
        return None


class SSE:
    def __init__(self, sample):
        self.sample = sample
        self.pending = b''
        self.lines = []
        self.size = 0
        self.event = None
        self.discard = False

    def oversize(self):
        self.pending = b''
        self.lines = []
        self.discard = True
        self.sample.finish('unavailable', 'oversize_event')

    def feed(self, chunk, at=None):
        at = time.monotonic() if at is None else at
        self.pending += chunk
        while b'\n' in self.pending:
            line, self.pending = self.pending.split(b'\n', 1)
            line = line.rstrip(b'\r')
            if not line:
                if not self.discard and self.lines:
                    raw = b'\n'.join(self.lines)
                    if raw.strip() != b'[DONE]':
                        value = decode(raw)
                        if isinstance(value, dict):
                            if 'type' not in value and self.event:
                                value['type'] = self.event
                            self.sample.consume(value, at)
                        else:
                            self.sample.store.diagnose('malformed_event')
                self.lines = []
                self.size = 0
                self.event = None
                self.discard = False
            elif line.startswith(b'event:'):
                self.event = line[6:].strip().decode('utf-8', errors='replace')[:128]
            elif line.startswith(b'data:') and not self.discard:
                data = line[5:]
                if data.startswith(b' '):
                    data = data[1:]
                self.size += len(data)
                if self.size > LIMIT:
                    self.oversize()
                else:
                    self.lines.append(data)
        if len(self.pending) > LIMIT:
            self.oversize()


def headers(source, websocket=False):
    excluded = HOP | ({'sec-websocket-key', 'sec-websocket-version', 'sec-websocket-extensions',
                        'sec-websocket-protocol', 'sec-websocket-accept'} if websocket else set())
    # Connection can nominate additional hop-by-hop headers.
    excluded |= {v.strip().lower() for v in source.get('Connection', '').split(',') if v.strip()}
    return [(k, v) for k, v in source.items() if k.lower() not in excluded]


class BodyObserver:
    def __init__(self, sample, encoding):
        self.sample = sample
        self.parser = FormatObserver(sample)
        self.decoder = None
        self.supported = True
        if encoding in ('', 'identity'):
            pass
        elif encoding == 'gzip':
            self.decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        elif encoding == 'deflate':
            self.decoder = zlib.decompressobj()
        else:
            self.supported = False
            sample.finish('unavailable', 'unsupported_content_encoding')

    def feed(self, chunk, at):
        # Continue parsing correlated timing after completion, even for gzip streams.
        if not self.supported:
            return
        try:
            if self.decoder:
                chunk = self.decoder.decompress(chunk, LIMIT + 1)
                if len(chunk) > LIMIT or self.decoder.unconsumed_tail:
                    self.sample.finish('unavailable', 'oversize_event', at)
                    return
            self.parser.feed(chunk, at)
        except zlib.error:
            self.supported = False
            self.sample.finish('unavailable', 'unsupported_content_encoding', at)

    def end(self):
        self.parser.end()


class JSONObserver:
    """Observe bounded non-streaming JSON while forwarding its chunks immediately."""
    def __init__(self, sample):
        self.sample = sample
        self.pending = bytearray()
        self.last_received = None

    def feed(self, chunk, at):
        self.last_received = at
        if self.sample.done:
            return
        if len(self.pending) + len(chunk) > LIMIT:
            self.pending.clear()
            self.sample.finish('unavailable', 'oversize_event', at)
            return
        self.pending.extend(chunk)

    def end(self):
        if self.sample.done:
            return
        value = decode(self.pending)
        self.pending.clear()
        if not isinstance(value, dict):
            self.sample.finish('unavailable', 'malformed_event', self.last_received)
            return
        if value.get('type') in ('response.completed', 'response.failed', 'response.incomplete', 'error'):
            self.sample.consume(value, self.last_received)
        else:
            response = value.get('response') if isinstance(value.get('response'), dict) else value
            self.sample.consume({'type': 'response.completed', 'response': response}, self.last_received)


class FormatObserver:
    """Identify valid SSE/JSON framing, without trusting optional Content-Type."""
    def __init__(self, sample):
        self.sample = sample
        self.prefix = bytearray()
        self.parser = None

    def feed(self, chunk, at):
        if self.parser:
            self.parser.feed(chunk, at)
            return
        if self.sample.done:
            return
        self.prefix.extend(chunk)
        if len(self.prefix) > LIMIT:
            self.prefix.clear()
            self.sample.finish('unavailable', 'oversize_event', at)
            return
        probe = bytes(self.prefix).lstrip()
        if probe.startswith(b'\xef\xbb\xbf'):
            probe = probe[3:].lstrip()
        if probe.startswith((b'data:', b'event:', b':')):
            self.sample.response_format = 'sse'
            self.parser = SSE(self.sample)
        elif probe.startswith(b'{'):
            self.sample.response_format = 'json'
            self.parser = JSONObserver(self.sample)
        elif len(probe) > 128:
            self.prefix.clear()
            self.sample.finish('unavailable', 'non_streaming_response', at)
            return
        if self.parser:
            self.prefix.clear()
            self.parser.feed(probe, at)

    def end(self):
        if isinstance(self.parser, JSONObserver):
            self.parser.end()
        elif self.parser is None:
            self.sample.finish('unavailable', 'non_streaming_response')


def create_app(path=STATE, upstream='https://chatgpt.com'):
    store = Store(path)
    app = web.Application(client_max_size=128 * 1024 * 1024, handler_args={'auto_decompress': False})

    async def heartbeat():
        while True:
            await asyncio.sleep(1)
            store.publish()

    async def lifecycle(app):
        async with ClientSession(auto_decompress=False, trust_env=True,
                                 timeout=ClientTimeout(total=None, sock_connect=30),
                                 skip_auto_headers={'User-Agent', 'Accept-Encoding', 'Content-Type'}) as client:
            app[CLIENT] = client
            task = asyncio.create_task(heartbeat())
            try:
                yield
            finally:
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task
    app.cleanup_ctx.append(lifecycle)

    async def health(request):
        return web.json_response({'service': 'codex-speed-lite', 'version': SCHEMA,
                                  'storage_ok': store.storage_ok, 'active_requests': len(store.active)})

    async def forward(request):
        if not request.path.startswith('/backend-api/codex/') or '..' in request.path.split('/'):
            raise web.HTTPNotFound()
        url = upstream + request.raw_path
        client = request.app[CLIENT]
        sample = None
        tracker = None
        downstream = None
        try:
            if request.headers.get('Upgrade', '').lower() == 'websocket':
                protocols = tuple(p.strip() for p in request.headers.get('Sec-WebSocket-Protocol', '').split(',') if p.strip())
                async with client.ws_connect(url, headers=headers(request.headers, True), protocols=protocols,
                                             compress=0, max_msg_size=0, autoping=False) as remote:
                    downstream = web.WebSocketResponse(protocols=([remote.protocol] if remote.protocol else []),
                                                       compress=False, max_msg_size=0, autoping=False)
                    downstream.headers.extend(headers(remote._response.headers, True))
                    await downstream.prepare(request)
                    tracker = StreamTracker(store)

                    async def send_frame(destination, message):
                        if message.type == WSMsgType.TEXT:
                            await destination.send_str(message.data)
                        elif message.type == WSMsgType.BINARY:
                            await destination.send_bytes(message.data)
                        elif message.type == WSMsgType.PING:
                            await destination.ping(message.data)
                        elif message.type == WSMsgType.PONG:
                            await destination.pong(message.data)

                    async def outgoing():
                        async for message in downstream:
                            if message.type in (WSMsgType.TEXT, WSMsgType.BINARY):
                                tracker.outgoing(decode(message.data))
                            await send_frame(remote, message)

                    async def incoming():
                        async for message in remote:
                            received = time.monotonic()
                            await send_frame(downstream, message)
                            if message.type in (WSMsgType.TEXT, WSMsgType.BINARY):
                                tracker.incoming(decode(message.data), received)

                    tasks = [asyncio.create_task(outgoing()), asyncio.create_task(incoming())]
                    try:
                        finished, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                        for task in finished:
                            task.result()
                    finally:
                        for task in tasks:
                            task.cancel()
                        await asyncio.gather(*tasks, return_exceptions=True)
                        await downstream.close(code=remote.close_code or 1000)
                return downstream

            if request.method == 'POST' and request.path.rstrip('/').endswith('/responses'):
                sample = store.begin()
            forwarded = [(k, v) for k, v in headers(request.headers) if k.lower() != 'accept-encoding']
            forwarded.append(('Accept-Encoding', 'identity'))
            async with client.request(request.method, url, headers=forwarded,
                                      data=request.content.iter_any(), allow_redirects=False) as remote:
                downstream = web.StreamResponse(status=remote.status, headers=headers(remote.headers))
                await downstream.prepare(request)
                observer = None
                mime = remote.headers.get('Content-Type', '').lower().split(';', 1)[0].strip()
                encoding = remote.headers.get('Content-Encoding', '').lower().strip()
                if sample:
                    sample.http_status = remote.status
                    sample.response_format = {'text/event-stream': 'sse', 'application/octet-stream': 'octet',
                                              'application/json': 'json', 'text/html': 'html'}.get(mime, 'other')
                if sample and remote.status >= 300:
                    sample.finish('failed', 'upstream_http_error')
                elif sample:
                    # Native Codex accepts SSE even with absent/mislabelled MIME headers.
                    # Infer framing from bytes; only parsed final usage yields a rate.
                    observer = BodyObserver(sample, encoding)
                async for chunk in remote.content.iter_any():
                    received = time.monotonic()
                    await downstream.write(chunk)
                    if observer:
                        observer.feed(chunk, received)
                if observer:
                    observer.end()
                await downstream.write_eof()
                return downstream
        except asyncio.CancelledError:
            raise
        except Exception:
            # Do not log exception text, payloads, headers, URLs, or credentials.
            if sample:
                sample.finish('failed', 'upstream_connection_failed')
            if downstream is not None and downstream.prepared:
                if request.transport:
                    request.transport.close()
                return downstream
            return web.Response(status=502, text='Local API monitor could not reach upstream.')
        finally:
            if sample:
                sample.finish('cancelled', 'stream_ended_before_usage')
            if tracker:
                tracker.close()

    app.router.add_get('/health', health)
    app.router.add_route('*', '/{tail:.*}', forward)
    return app


if __name__ == '__main__':
    logging.disable(logging.CRITICAL)
    web.run_app(create_app(), host='127.0.0.1', port=PORT, access_log=None, print=None)
