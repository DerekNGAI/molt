import assert from 'node:assert/strict';
import { test } from 'node:test';
test('Node fixture uses the declared toolchain', () => {
  assert.ok(Number(process.versions.node.split('.')[0]) >= 24);
});
