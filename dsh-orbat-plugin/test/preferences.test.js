import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import test from 'node:test';
import {
  createPreferencesStore,
  getDefaultOutputDirectory,
  normalizePreferences,
  registerPreferencesRoutes,
} from '../lib/preferences.js';

async function temporaryDirectory(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'orbat-preferences-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

class FakeResponse extends EventEmitter {
  constructor() {
    super();
    this.statusCode = 200;
    this.headers = {};
    this.writableEnded = false;
    this.destroyed = false;
    this.body = '';
  }
  setHeader(name, value) { this.headers[name.toLowerCase()] = value; }
  end(body = '') {
    this.body = body;
    this.writableEnded = true;
  }
}

function request({ url = '/orbat-agent/settings', method = 'GET', body, headers = {} } = {}) {
  const req = new EventEmitter();
  req.url = url;
  req.method = method;
  req.headers = {
    host: '127.0.0.1:64130',
    origin: 'http://127.0.0.1:64130',
    ...headers,
  };
  if (body !== undefined) {
    queueMicrotask(() => {
      req.emit('data', Buffer.from(body));
      req.emit('end');
    });
  }
  return req;
}

function captureRoute(t, store, selfCheck = async () => ({ success: true })) {
  let registered;
  let disposed = false;
  const dispose = registerPreferencesRoutes({
    register(route) {
      registered = route;
      return () => { disposed = true; };
    },
  }, { store, selfCheck });
  t.after(() => dispose());
  return { route: registered, wasDisposed: () => disposed };
}

function responseJson(response) {
  return JSON.parse(response.body);
}

test('preferences default values and output path normalization are explicit', () => {
  assert.deepEqual(normalizePreferences({}), { whiteBackground: true, outputDirectory: '' });
  assert.deepEqual(normalizePreferences({ whiteBackground: false, outputDirectory: 'C:\\Orbat\\Exports\\' }), {
    whiteBackground: false,
    outputDirectory: 'C:\\Orbat\\Exports\\',
  });
  assert.equal(getDefaultOutputDirectory({ userProfile: 'C:\\Users\\Example' }), 'C:\\Users\\Example\\Documents\\ORBAT Generator');
  assert.throws(() => normalizePreferences({ outputDirectory: 'relative\\folder' }), { code: 'INVALID_OUTPUT_DIRECTORY' });
  assert.throws(() => normalizePreferences({ outputDirectory: '\\\\?\\C:\\device' }), { code: 'INVALID_OUTPUT_DIRECTORY' });
  assert.throws(() => normalizePreferences({ unknown: true }), { code: 'UNKNOWN_SETTING' });
  assert.throws(() => normalizePreferences({ whiteBackground: 'false' }), { code: 'INVALID_BACKGROUND' });
});

test('preferences updates are serialized, atomic, and merge individual fields', async (t) => {
  const base = await temporaryDirectory(t);
  const store = createPreferencesStore({ localAppData: base, userProfile: 'C:\\Users\\Example' });
  assert.deepEqual(await store.read(), { whiteBackground: true, outputDirectory: '' });
  await Promise.all([
    store.update({ whiteBackground: false }),
    store.update({ outputDirectory: 'C:\\Orbat\\Exports' }),
  ]);
  assert.deepEqual(await store.read(), { whiteBackground: false, outputDirectory: 'C:\\Orbat\\Exports' });
});

test('settings routes return defaults, update preferences, and reject non-local callers', async (t) => {
  const base = await temporaryDirectory(t);
  const store = createPreferencesStore({ localAppData: base, userProfile: 'C:\\Users\\Example' });
  const { route } = captureRoute(t, store);

  const getResponse = new FakeResponse();
  await route.handler(request(), getResponse);
  assert.equal(getResponse.statusCode, 200);
  assert.equal(getResponse.headers['cache-control'], 'no-store');
  assert.deepEqual(responseJson(getResponse).settings, { whiteBackground: true, outputDirectory: '' });
  assert.equal(responseJson(getResponse).defaultOutputDirectory, 'C:\\Users\\Example\\Documents\\ORBAT Generator');

  const putResponse = new FakeResponse();
  await route.handler(request({
    method: 'PUT',
    body: JSON.stringify({ whiteBackground: false, outputDirectory: 'C:\\Orbat\\Exports' }),
    headers: { 'content-type': 'application/json' },
  }), putResponse);
  assert.equal(putResponse.statusCode, 200);
  assert.deepEqual(responseJson(putResponse).settings, { whiteBackground: false, outputDirectory: 'C:\\Orbat\\Exports' });

  const remoteResponse = new FakeResponse();
  await route.handler(request({ headers: { origin: 'https://example.invalid' } }), remoteResponse);
  assert.equal(remoteResponse.statusCode, 403);

  const fakeLoopbackName = new FakeResponse();
  await route.handler(request({ headers: { origin: 'http://127.attacker.invalid' } }), fakeLoopbackName);
  assert.equal(fakeLoopbackName.statusCode, 403);

  const fakeJsonType = new FakeResponse();
  await route.handler(request({ method: 'PUT', body: '{}', headers: { 'content-type': 'application/jsonp' } }), fakeJsonType);
  assert.equal(fakeJsonType.statusCode, 400);
});

test('self-check route aborts the shared Host operation when its response closes', async (t) => {
  const base = await temporaryDirectory(t);
  const store = createPreferencesStore({ localAppData: base, userProfile: 'C:\\Users\\Example' });
  let signal;
  let finish;
  let started;
  const startedPromise = new Promise((resolve) => { started = resolve; });
  const { route } = captureRoute(t, store, ({ signal: received }) => {
    signal = received;
    started();
    return new Promise((resolve) => { finish = resolve; });
  });

  const response = new FakeResponse();
  const handling = route.handler(request({
    url: '/orbat-agent/selfcheck',
    method: 'POST',
    body: '{}',
    headers: { 'content-type': 'application/json' },
  }), response);
  await startedPromise;
  response.destroyed = true;
  response.emit('close');
  assert.equal(signal.aborted, true);
  finish({ success: false });
  await handling;
});

test('settings route disposer is returned to the Host lifecycle owner', (t) => {
  const store = createPreferencesStore({ localAppData: path.join(os.tmpdir(), 'orbat-route-disposer-test') });
  const captured = captureRoute(t, store);
  assert.equal(typeof captured.route.handler, 'function');
  assert.equal(captured.wasDisposed(), false);
});
