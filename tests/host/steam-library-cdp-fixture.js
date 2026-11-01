// A delayed, local CDP peer. No Steam, guest code or user data.
const http = require('http'), crypto = require('crypto'), assert = require('assert');
let sampled = false; const enabled = new Set();
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
      if (opcode === 8) { assert(sampled); socket.end();server.close(); continue; }
      if (opcode !== 1) continue;
      const command = JSON.parse(payload.toString());
      if (['Runtime.enable','Page.enable','Log.enable','Network.enable'].includes(command.method)) {
        enabled.add(command.method); reply(command.id, {});
      } else if (command.method === 'Runtime.evaluate') {
        assert.strictEqual(enabled.size, 4); assert.strictEqual(command.params.throwOnSideEffect, true);
        assert.strictEqual(command.params.returnByValue, true);
        for (const text of ['defineProperty', 'addEventListener', 'setInterval', 'addBinding', 'Reflect.apply']) assert(!command.params.expression.includes(text));
        const event=(method,params)=>{const body=Buffer.from(JSON.stringify({method,params}));const head=body.length<126?Buffer.from([0x81,body.length]):Buffer.from([0x81,126,body.length>>8,body.length&255]);socket.write(Buffer.concat([head,body]));};
        for(let i=0;i<200;i++)event('Runtime.consoleAPICalled',{type:'warning',args:[{value:'startup warning SECRET'}]});
        const frames={callFrames:[{functionName:'AppStore.Init',url:'https://steamloopback.host/chunk.js?token=SECRET',lineNumber:1,columnNumber:44}]};
        event('Page.navigatedWithinDocument',{url:'https://steamloopback.host/library/home?token=SECRET'});
        event('Runtime.consoleAPICalled',{type:'error',args:[{value:'Remote call failed SECRET'}],stackTrace:frames});
        event('Runtime.exceptionThrown',{exceptionDetails:{text:'Uncaught (in promise)',exception:{description:"TypeError: Cannot read properties of undefined (reading 'get') SECRET"},stackTrace:frames}});
        event('Network.requestWillBeSent',{requestId:'lib',request:{url:'https://steamloopback.host/library.js?token=SECRET'}});
        event('Network.responseReceived',{requestId:'lib',response:{url:'https://steamloopback.host/library.js?token=SECRET',status:503}});
        event('Network.loadingFailed',{requestId:'lib',errorText:'net::ERR_CONNECTION_REFUSED'});
        event('Network.webSocketCreated',{requestId:'ws',url:'ws://127.0.0.1:27060/client?cookie=SECRET'});
        event('Network.webSocketHandshakeResponseReceived',{requestId:'ws',response:{status:101,headers:{authorization:'SECRET'}}});
        event('Network.webSocketFrameError',{requestId:'ws',errorMessage:'SECRET'});
        setTimeout(()=>{sampled=true;reply(command.id,{result:{value:{store:true,ready:true,count:19,cs2:true,apps:true,secret:'SECRET'}}});console.log('PASS passive CDP events and delayed read-only snapshot; no script hooks requested');},40);
      } else { throw new Error('observer requested non-passive command '+command.method); }
    }
  });
});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
setTimeout(() => { if (!sampled) { console.error('CDP fixture timed out'); process.exit(1); } }, 8000).unref();
