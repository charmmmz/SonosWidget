import assert from 'node:assert/strict';
import { test } from 'node:test';

import { shouldIgnoreHttpAutoLog } from './httpLogging.js';

test('ignores high-frequency CS2 gamestate posts from HTTP auto logging', () => {
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/cs2/gamestate' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/cs2/gamestate?tick=1' }), true);
});

test('keeps normal HTTP auto logging enabled for other endpoints', () => {
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/health' }), false);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/cs2/status' }), false);
  assert.equal(shouldIgnoreHttpAutoLog({ url: undefined }), false);
});
