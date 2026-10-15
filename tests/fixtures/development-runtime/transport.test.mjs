import assert from 'node:assert/strict';
import { test } from 'node:test';
import http from 'node:http';
import net from 'node:net';

test('HTTP and WebSocket upgrade/data remain TCP bytes through a loopback tunnel', { timeout: 5000 }, async t => {
  const connections = new Set();
  const source = http.createServer((_request, response) => response.end('application'));
  source.on('connection', socket => { connections.add(socket); socket.on('close', () => connections.delete(socket)); });
  source.on('upgrade', (_request, socket) => { socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n'); socket.on('data', bytes => socket.write(bytes)); });
  await new Promise(resolve => source.listen(0, '127.0.0.1', resolve));
  const tunnel = net.createServer(client => {
    const upstream = net.connect(source.address().port, '127.0.0.1');
    for (const socket of [client, upstream]) { connections.add(socket); socket.on('close', () => connections.delete(socket)); socket.on('error', () => { client.destroy(); upstream.destroy(); }); }
    client.pipe(upstream); upstream.pipe(client);
  });
  await new Promise(resolve => tunnel.listen(0, '127.0.0.1', resolve));
  t.after(async () => { for (const socket of connections) socket.destroy(); await Promise.all([new Promise(resolve => source.close(resolve)), new Promise(resolve => tunnel.close(resolve))]); });
  const port = tunnel.address().port;
  assert.equal(await (await fetch(`http://127.0.0.1:${port}`)).text(), 'application');
  const socket = net.connect(port, '127.0.0.1');
  socket.write('GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n');
  const header = await new Promise(resolve => socket.once('data', resolve));
  assert.match(header.toString(), /101 Switching Protocols/);
  const frame = Buffer.from([0x81, 0x82, 1, 2, 3, 4, 0x69, 0x6b]);
  socket.write(frame);
  assert.deepEqual(await new Promise(resolve => socket.once('data', resolve)), frame);
  socket.destroy();
});
