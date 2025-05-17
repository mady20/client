const express = require('express');
const morgan = require('morgan');
const cors = require('cors');
const bodyParser = require('body-parser');
const app = express();
const PORT = 3000;

app.use(cors()); 
app.use(morgan('dev')); 
app.use(express.json()); 

let users = [
  { id: 1, name: 'Alice', email: 'alice@example.com' },
  { id: 2, name: 'Bob', email: 'bob@example.com' }
];
let nextId = 3;

const VALID_API_KEY = 'key';
const VALID_BEARER_TOKEN = 'token1234';

// Bearer Token Auth Middleware
const authenticateBearer = (req, res, next) => {
  const authHeader = req.header('authorization');
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing or invalid Bearer token' });
  }

  const token = authHeader.split(' ')[1];
  if (token !== VALID_BEARER_TOKEN) {
    return res.status(403).json({ error: 'Invalid Bearer token' });
  }

  next();
};

 // API Key Auth Middleware
const authenticateApiKey = (req, res, next) => {
  const apiKey = req.header('x-api-key');
  if (!apiKey) {
    return res.status(401).json({ error: 'Missing API key' });
  }

  if (apiKey !== VALID_API_KEY) {
    return res.status(403).json({ error: 'Invalid API key' });
  }

  next();
};
 


app.get('/users', (req, res) => {
  const { name } = req.query;
  if (name) {
    const filteredUsers = users.filter(u => u.name.toLowerCase().includes(name.toLowerCase()));
    return res.json(filteredUsers);
  }
  res.json(users);
});

app.get('/users/:id', (req, res) => {
  const id = parseInt(req.params.id);
  if (id === 99) return res.status(200).json({ id: 99, name: 'Ghost', email: 'ghost@example.com' });
  if (id === 100) return res.status(200).json({ id: 100, name: 'Nobody', email: 'nobody@example.com' });
  const user = users.find(u => u.id === id);
  if (user) return res.end(user.name);
  res.status(404).json({ error: 'User not found' });
});

app.post('/users', (req, res) => {
  if (!req.body || typeof req.body !== 'object') {
    return res.status(400).json({ error: 'Invalid or missing JSON body' });
  }
  const { name, email } = req.body;
  if (!name || !email) {
    return res.status(400).json({ error: 'Name and email are required' });
  }
  if (!email.includes('@')) {
    return res.status(400).json({ error: 'Invalid email format' });
  }
  const user = { id: nextId++, name, email };
  users.push(user);
  res.status(201).json(user);
});

app.put('/users/:id', (req, res) => {
  if (!req.body || typeof req.body !== 'object') {
    return res.status(400).json({ error: 'Invalid or missing JSON body' });
  }
  const id = parseInt(req.params.id);
  const user = users.find(u => u.id === id);
  if (!user) return res.status(404).json({ error: 'User not found' });
  const { name, email } = req.body;
  if (name) user.name = name;
  if (email) {
    if (!email.includes('@')) {
      return res.status(400).json({ error: 'Invalid email format' });
    }
    user.email = email;
  }
  res.json(user);
});

app.patch('/users/:id', (req, res) => {
  if (!req.body || typeof req.body !== 'object') {
    return res.status(400).json({ error: 'Invalid or missing JSON body' });
  }
  const id = parseInt(req.params.id);
  const user = users.find(u => u.id === id);
  if (!user) return res.status(404).json({ error: 'User not found' });
  const { name, email } = req.body;
  if (name === undefined && email === undefined) {
    return res.status(400).json({ error: 'At least one field (name or email) must be provided' });
  }
  if (name) user.name = name;
  if (email) {
    if (!email.includes('@')) {
      return res.status(400).json({ error: 'Invalid email format' });
    }
    user.email = email;
  }
  res.json(user);
});

app.delete('/users/:id', (req, res) => {
  const id = parseInt(req.params.id);
  const idx = users.findIndex(u => u.id === id);
  if (idx === -1) return res.status(404).json({ error: 'User not found' });
  users.splice(idx, 1);
  res.status(204).send();
});

app.get('/echo-header', (req, res) => {
  const headers = {
    'X-Test-Header': req.headers['x-test-header'] || '',
    'X-Another-Header': req.headers['x-another-header'] || ''
  };
  res.json(headers);
});

app.get('/error', (req, res) => {
  const status = parseInt(req.query.status) || 500;
  if (![400, 401, 403, 404, 429, 500].includes(status)) {
    return res.status(400).json({ error: 'Invalid status code. Use 400, 401, 403, 404, 429, or 500' });
  }
  res.status(status).json({ error: `Error with status ${status}` });
});

app.get('/slow', (req, res) => {
  const delay = parseInt(req.query.delay) || 10000; // Default 10s
  setTimeout(() => {
    res.json({ message: `Delayed response after ${delay}ms` });
  }, delay);
});

app.get('/protected/bearer', authenticateBearer, (req, res) => {
  res.json({ message: 'Access granted!'});
});

app.get('/protected/apikey', authenticateApiKey, (req, res) => {
  res.json({ message: 'Access granted with API key', user: 'Authenticated User' });
});

let requestCount = 0;
const resetInterval = 60000; // 1 minute
setInterval(() => { requestCount = 0; }, resetInterval);
app.get('/ratelimit', (req, res) => {
  requestCount++;
  if (requestCount > 5) {
    return res.status(429).json({ error: 'Too many requests' });
  }
  res.json({ message: 'Request allowed', count: requestCount });
});

app.listen(PORT, () => console.log(`Server running on http://localhost:${PORT}`));
console.log('Available endpoints:');
console.log(`  GET    http://localhost:${PORT}/users?name=<query>`);
console.log(`  GET    http://localhost:${PORT}/users/:id`);
console.log(`  POST   http://localhost:${PORT}/users`);
console.log(`  PUT    http://localhost:${PORT}/users/:id`);
console.log(`  PATCH  http://localhost:${PORT}/users/:id`);
console.log(`  DELETE http://localhost:${PORT}/users/:id`);
console.log(`  GET    http://localhost:${PORT}/echo-header`);
console.log(`  GET    http://localhost:${PORT}/error?status=<code>`);
console.log(`  GET    http://localhost:${PORT}/slow?delay=<ms>`);
console.log(`  GET    http://localhost:${PORT}/protected/bearer (Requires Bearer: ${VALID_BEARER_TOKEN})`);
console.log(`  GET    http://localhost:${PORT}/protected/apikey (Requires X-API-Key: ${VALID_API_KEY})`);
console.log(`  GET    http://localhost:${PORT}/ratelimit`);
