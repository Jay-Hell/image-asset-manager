// Not a test file (the runner takes *.test.js only). import.test.js runs prepareImportArgs here, in a
// child process with a time limit, so a guard that blocks on a FIFO fails the test rather than
// hanging the runner. Prints {ok, media_type} or {error} as one JSON line.

import { prepareImportArgs } from '../src/tools.js';

try {
  const sent = prepareImportArgs({ path: process.argv[2] });
  process.stdout.write(JSON.stringify({ ok: true, media_type: sent.media_type }));
} catch (error) {
  process.stdout.write(JSON.stringify({ error: error.message }));
}
