// The first setup file of a vitest worker under enact's Node recorder (node_marker.mjs
// adds it): it names the worker's test file to the recorder enact preloads
// (`globalThis[Symbol.for('enact.node')]`), so what the worker runs from here on is that
// file's (its start-up before is every file's), and ends the file's record after its last
// hook: the recorder writes then, not only when vitest stops the worker, which may cut a
// slow write short or (a thread's terminate()) leave none. Imports no 'vitest': the worker's
// own API is `globalThis.__vitest_index__`.
const file = globalThis.__vitest_worker__?.filepath;
const recorder = globalThis[Symbol.for('enact.node')];
if (file && recorder) {
  recorder.target(file);
  // A cleanup beforeAll returns runs after the file's every afterAll: after this first
  // setup file's hooks, last ('stack' order).
  globalThis.__vitest_index__?.beforeAll?.(() => () => recorder.end());
}
