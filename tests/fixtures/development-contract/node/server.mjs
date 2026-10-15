import { createServer } from 'node:http';
createServer((_request, response) => response.end('molt development fixture\n')).listen(3000, '0.0.0.0');
