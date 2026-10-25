#!/usr/bin/env node
// The `iam` command. All of it is in ../src/iam.js, where the tests reach it.
import { run } from '../src/iam.js';

process.exitCode = await run(process.argv.slice(2));
