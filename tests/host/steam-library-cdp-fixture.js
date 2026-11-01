// A delayed, local CDP peer. No Steam, guest code or user data.
const http = require('http'), crypto = require('crypto'), assert = require('assert');
let samples = 0, summary = false, released = false;
const server = http.createServer();
server.on('upgrade', (request, socket) => {
  const accept = crypto.createHash('sha1').update(request.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
  const reply = (id, result) => {
    const body = Buffer.from(JSON.stringify({id, result}));
    const head = body.length < 126 ? Buffer.from([0x81, body.length]) : Buffer.from([0x81, 126, body.length >> 8, body.length & 255]);
    socket.write(Buffer.concat([head, body]));
  };
  let buffer = Buffer.alloc(0);
  socket.on('data', bytes => {
    buffer = Buffer.concat([buffer, bytes]);
    while (buffer.length >= 2) {
      const opcode = buffer[0] & 15, masked = buffer[1] & 128;
      let length = buffer[1] & 127, offset = 2;
      if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); offset = 4; }
      assert(length !== 127, 'fixture messages must be small');
      const maskBytes = masked ? 4 : 0;
      if (buffer.length < offset + maskBytes + length) return;
      const mask = buffer.subarray(offset, offset + maskBytes); offset += maskBytes;
      const payload = Buffer.from(buffer.subarray(offset, offset + length)); buffer = buffer.subarray(offset + length);
      if (masked) for (let i = 0; i < length; i++) payload[i] ^= mask[i % 4];
      if (opcode === 8) { socket.end(); continue; }
      if (opcode !== 1) continue;
      const command = JSON.parse(payload.toString());
      if (command.method === 'Runtime.evaluate') {
        assert(!released); setTimeout(() => reply(command.id, {result: {objectId: 'promise'}}), 15);
      } else if (command.method === 'Runtime.getProperties') {
        assert(!released); samples++;
        const internalProperties = [{name: '[[PromiseState]]', value: {value: samples < 6 ? 'pending' : 'fulfilled'}}];
        if (samples === 6) internalProperties.push({name: '[[PromiseResult]]', value: {objectId: 'result'}});
        setTimeout(() => reply(command.id, {internalProperties}), 15);
      } else if (command.method === 'Runtime.callFunctionOn') {
        assert(!released); setTimeout(() => { summary = true; reply(command.id, {result: {value: {type: 'array', count: 1, cs2: true}}}); }, 80);
      } else if (command.method === 'Runtime.releaseObjectGroup') {
        assert.strictEqual(samples, 6); assert(summary, 'object group released before final result was inspected');
        released = true; reply(command.id, {});
        console.log('PASS delayed CDP final sample precedes object-group release');
        setTimeout(() => { socket.end(); server.close(); }, 100);
      } else { throw new Error('unexpected command ' + command.method); }
    }
  });
});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
setTimeout(() => { if (!released) { console.error('CDP fixture timed out'); process.exit(1); } }, 8000).unref();
