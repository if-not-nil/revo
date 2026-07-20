import { readFileSync } from 'fs';
import { Revo, run } from './revo.js';

const wasmBuffer = readFileSync('examples/wasm/revo.wasm');

async function runTests() {
	let failures = 0, tests = 0;

	const assert = (c, m) => {
		if (!c) throw new Error(m || 'assertion failed');
	};
	const assertInc = (s, sub, label) => {
		if (!s.includes(sub))
			throw new Error(`${label}: expected "${sub}" in ${JSON.stringify(s)}`);
	};

	const runTest = async (name, fn) => {
		tests++;
		try {
			await fn(); console.log(`PASS ${name}`);
		} catch (e) {
			console.log(`FAIL ${name}: ${e.message || e}`)
			failures++;
		}
	};

	await runTest('create and destroy', async () => {
		const r = await Revo.fromBuffer(wasmBuffer, { stdout: () => { }, stderr: () => { } });
		assert(r instanceof Revo);
		r.destroy();
	});

	await runTest('run convenience', async () => {
		const r = await run('42', { wasmBuffer });
		assert(r.ok && r.value === '42', JSON.stringify(r));
	});

	await runTest('eval 42', async () => {
		const r = await run('42', { wasmBuffer });
		assert(r.ok && r.value === '42', JSON.stringify(r));
	});

	await runTest('eval unicode', async () => {
		const r = await run('"hëllö wörld"', { wasmBuffer });
		assert(r.ok && r.value === 'hëllö wörld', JSON.stringify(r));
	});

	await runTest('eval expression', async () => {
		const r = await run('(1 + 2) * 3', { wasmBuffer });
		assert(r.ok && r.value === '9', JSON.stringify(r));
	});

	await runTest('compile error', async () => {
		const r = await run('!', { wasmBuffer });
		assert(!r.ok, 'expected compile error');
		assertInc(r.value || '', 'error', 'compile error');
	});

	await runTest('runtime error', async () => {
		const r = await run('1 + :foo', { wasmBuffer });
		assert(!r.ok, 'expected runtime error');
		assertInc(r.value || '', 'error', 'runtime error');
	});

	await runTest('print registered', async () => {
		const r = await run('print', { wasmBuffer });
		assert(r.ok, `print not defined: ${r.value}`);
		assert(r.value && r.value.startsWith('#fn'),
			`print should be a function, got: ${JSON.stringify(r.value)}`);
	});

	await runTest('print works', async () => {
		const r = await run('print("hi", "asdf")', { wasmBuffer });
		assert(r.ok && r.value === ':ok', JSON.stringify(r));
	});

	await runTest('empty code', async () => {
		const r = await run('', { wasmBuffer });
		assert(r.ok && r.value === '', JSON.stringify(r));
	});

	await runTest('stdout callback', async () => {
		const chunks = [];
		await run('print("hello world")', { wasmBuffer, stdout(text) { chunks.push(text); } });
		assert(chunks.length > 0, `expected stdout chunks, got ${JSON.stringify(chunks)}`);
		const all = chunks.join('');
		assert(all.includes('hello world'),
			`expected "hello world" in stdout, got ${JSON.stringify(all)}`);
	});

	await runTest('eval large output', async () => {
		const r = await run("'hello ' ~ 'world ' ~ 'hello ' ~ 'world ' ~ 'hello ' ~ 'world ' ~ 'hello ' ~ 'world ' ~ 'hello ' ~ 'world ' ~ 'hello ' ~ 'world ' ~ 'hello ' ~ 'world ' ~ 'hello ' ~ 'world ' ~ 'hello ' ~ 'world ' ~ 'hello ' ~ 'world ' ~ 'hello ' ~ 'world ' ~ 'hello ' ~ 'world '", { wasmBuffer });
		assert(r.ok);
		assert(r.value.startsWith('hello world'),
			`expected hello world, got ${JSON.stringify(r.value.slice(0, 30))}`);
		assert(r.value.length > 140, `expected >140 chars, got ${r.value.length}`);
	});

	await runTest('multiple evals', async () => {
		const revo = await Revo.fromBuffer(wasmBuffer);
		assert(revo.eval('1 + 2').value === '3', 'first eval');
		assert(revo.eval('10 * 3').value === '30', 'second eval');
		assert(revo.eval("'ok'").value === 'ok', 'third eval');
		revo.destroy();
	});

	await runTest('reset', async () => {
		const revo = await Revo.fromBuffer(wasmBuffer);
		revo.reset();
		const r = revo.eval('print("after reset")');
		assert(r.ok && r.value === ':ok', JSON.stringify(r));
		revo.destroy();
	});

	await runTest('multiple independent instances', async () => {
		const a = await Revo.fromBuffer(wasmBuffer);
		const b = await Revo.fromBuffer(wasmBuffer);
		assert(a.eval('1 + 2').value === '3', 'a: eval');
		assert(b.eval('4 + 5').value === '9', 'b: eval');
		a.destroy();
		b.destroy();
	});

	await runTest('alloc 0 returns null', async () => {
		const revo = await Revo.fromBuffer(wasmBuffer);
		assert(revo.raw.revo_wasm_alloc(0n) === 0n);
		revo.destroy();
	});

	await runTest('free 0 does not crash', async () => {
		const revo = await Revo.fromBuffer(wasmBuffer);
		const p = revo.raw.revo_wasm_alloc(10n);
		assert(p !== 0n);
		revo.raw.revo_wasm_free(p, 0n);
		revo.raw.revo_wasm_free(p, 10n);
		revo.destroy();
	});

	await runTest('alloc then free then alloc', async () => {
		const revo = await Revo.fromBuffer(wasmBuffer);
		const p1 = revo.raw.revo_wasm_alloc(100n);
		assert(p1 !== 0n);
		revo.raw.revo_wasm_free(p1, 100n);
		const p2 = revo.raw.revo_wasm_alloc(200n);
		assert(p2 !== 0n);
		revo.raw.revo_wasm_free(p2, 200n);
		revo.destroy();
	});

	await runTest('eval after memory growth', async () => {
		const revo = await Revo.fromBuffer(wasmBuffer);
		const a1 = revo.raw.revo_wasm_alloc(100000n);
		assert(a1 !== 0n);
		const a2 = revo.raw.revo_wasm_alloc(100000n);
		assert(a2 !== 0n);
		assert(revo.eval('99').value === '99');
		revo.raw.revo_wasm_free(a1, 100000n);
		revo.raw.revo_wasm_free(a2, 100000n);
		revo.destroy();
	});

	await runTest('deinit + reinit', async () => {
		const revo = await Revo.fromBuffer(wasmBuffer);
		revo.raw.revo_wasm_deinit();
		assert(revo.raw.revo_wasm_init());
		const r = revo.eval('7');
		assert(r.ok && r.value === '7');
		revo.destroy();
	});

	console.log(failures > 0 ? `${failures}/${tests} FAILED` : `ALL ${tests} PASSED`);
	if (failures > 0) process.exit(1);
}

runTests().catch(err => { console.error(err); process.exit(1); });
