// Bridges stdin/stdout (invoked by WSL2 socat over WSL interop) directly to
// Windows Apple Mobile Device Service on 127.0.0.1:27015.
// Because this runs inside Windows node.exe over WSL interop pipes, it bypasses
// Windows Defender Firewall on vEthernet (WSL) and requires no Admin privileges.
const net = require('net');

const socket = net.connect(27015, '127.0.0.1');
process.stdin.pipe(socket);
socket.pipe(process.stdout);

socket.on('close', () => process.exit(0));
socket.on('error', () => process.exit(1));
process.stdin.on('end', () => socket.end());
