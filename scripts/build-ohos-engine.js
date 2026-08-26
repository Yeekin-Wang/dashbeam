#!/usr/bin/env node

import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(__dirname, '..')
const engineDir = path.join(root, 'engine')
const cargoManifest = path.join(engineDir, 'Cargo.toml')
const cargoTargetDir = path.join(engineDir, 'target')

const ABI_CONFIG = {
	'arm64-v8a': {
		rustTarget: 'aarch64-unknown-linux-ohos',
		clangTarget: 'aarch64-linux-ohos',
		compilerPrefix: 'aarch64-unknown-linux-ohos',
	},
	x86_64: {
		rustTarget: 'x86_64-unknown-linux-ohos',
		clangTarget: 'x86_64-linux-ohos',
		compilerPrefix: 'x86_64-unknown-linux-ohos',
	},
}

function fail(message) {
	console.error(`build-ohos-engine: ${message}`)
	process.exit(1)
}

function parseArgs(argv) {
	let abi
	let ndk

	for (let index = 0; index < argv.length; index += 1) {
		const argument = argv[index]
		if (argument === '--abi' || argument === '--ndk') {
			const value = argv[index + 1]
			if (!value || value.startsWith('--')) {
				fail(`${argument} requires a value`)
			}
			if (argument === '--abi') {
				abi = value
			} else {
				ndk = value
			}
			index += 1
			continue
		}
		fail(`unknown argument: ${argument}`)
	}

	if (!abi) {
		fail('missing --abi (expected arm64-v8a or x86_64)')
	}
	if (!ABI_CONFIG[abi]) {
		fail(`unsupported ABI "${abi}" (expected arm64-v8a or x86_64)`)
	}
	if (!ndk) {
		fail('missing --ndk <path>')
	}

	return { abi, ndk: path.resolve(ndk) }
}

function run(command, args, options = {}) {
	const result = spawnSync(command, args, {
		cwd: options.cwd ?? root,
		env: options.env ?? process.env,
		stdio: options.stdio ?? 'inherit',
		shell: false,
	})
	if (result.error) {
		fail(`failed to run ${command}: ${result.error.message}`)
	}
	if (result.status !== 0) {
		process.exit(result.status ?? 1)
	}
	return result
}

function resolveRustup() {
	if (process.env.RUSTUP && fs.existsSync(process.env.RUSTUP)) {
		return process.env.RUSTUP
	}

	const lookup = spawnSync(
		process.platform === 'win32' ? 'where.exe' : 'which',
		['rustup'],
		{
			encoding: 'utf8',
			shell: false,
		}
	)
	if (lookup.status === 0) {
		const resolved = lookup.stdout.trim().split(/\r?\n/)[0]
		if (resolved) {
			return resolved
		}
	}

	const homeRustup = path.join(
		os.homedir(),
		'.cargo',
		'bin',
		`rustup${process.platform === 'win32' ? '.exe' : ''}`
	)
	if (fs.existsSync(homeRustup)) {
		return homeRustup
	}
	return null
}

function requireDirectory(directory, label) {
	if (!fs.existsSync(directory) || !fs.statSync(directory).isDirectory()) {
		fail(`${label} directory not found: ${directory}`)
	}
}

function requireTool(directory, name) {
	for (const candidate of [
		path.join(directory, name),
		path.join(directory, `${name}.exe`),
	]) {
		if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
			return candidate
		}
	}
	fail(`required NDK tool not found: ${path.join(directory, name)}`)
}

function normalizedPath(value) {
	return value.replaceAll('\\', '/')
}

function shellQuoted(value) {
	return `"${normalizedPath(value).replaceAll('"', '\\"')}"`
}

function targetEnvironment(config, ndk) {
	const llvmBin = path.join(ndk, 'llvm', 'bin')
	const sysroot = path.join(ndk, 'sysroot')
	requireDirectory(llvmBin, 'NDK LLVM')
	requireDirectory(sysroot, 'NDK sysroot')

	const cc = requireTool(
		llvmBin,
		process.platform === 'win32' ? 'clang' : `${config.compilerPrefix}-clang`
	)
	const cxx = requireTool(
		llvmBin,
		process.platform === 'win32'
			? 'clang++'
			: `${config.compilerPrefix}-clang++`
	)
	const ar = requireTool(llvmBin, 'llvm-ar')
	const flags = `--target=${config.clangTarget} --sysroot=${shellQuoted(sysroot)}`
	const env = {
		...process.env,
		CC_SHELL_ESCAPED_FLAGS: '1',
		CARGO_TARGET_DIR: cargoTargetDir,
		CARGO_ENCODED_RUSTFLAGS: [
			`-Clink-arg=--target=${config.clangTarget}`,
			`-Clink-arg=--sysroot=${normalizedPath(sysroot)}`,
		].join('\u001f'),
	}

	const targetSuffixes = [
		config.rustTarget,
		config.rustTarget.replaceAll('-', '_'),
	]
	for (const suffix of targetSuffixes) {
		env[`CC_${suffix}`] = cc
		env[`CXX_${suffix}`] = cxx
		env[`AR_${suffix}`] = ar
		env[`CFLAGS_${suffix}`] = flags
		env[`CXXFLAGS_${suffix}`] = flags
	}

	const cargoTargetKey = config.rustTarget.toUpperCase().replaceAll('-', '_')
	env[`CARGO_TARGET_${cargoTargetKey}_LINKER`] = cc
	delete env.RUSTFLAGS
	return env
}

const { abi, ndk } = parseArgs(process.argv.slice(2))
requireDirectory(ndk, 'OHOS NDK')

const config = ABI_CONFIG[abi]
const rustup = resolveRustup()
if (!rustup) {
	fail('rustup not found in PATH or ~/.cargo/bin')
}

const toolchain =
	process.platform === 'win32' ? '1.91-x86_64-pc-windows-gnu' : '1.91'
const toolchainProbe = spawnSync(
	rustup,
	['run', toolchain, 'rustc', '--version'],
	{
		stdio: 'ignore',
		shell: false,
	}
)
if (toolchainProbe.status !== 0) {
	run(rustup, [
		'toolchain',
		'install',
		toolchain,
		'--profile',
		'minimal',
		'--no-self-update',
	])
}

run(rustup, ['target', 'add', config.rustTarget, '--toolchain', toolchain])

const env = targetEnvironment(config, ndk)
run(
	rustup,
	[
		'run',
		toolchain,
		'cargo',
		'build',
		'--manifest-path',
		cargoManifest,
		'--package',
		'dashbeam-ohos-bridge',
		'--target',
		config.rustTarget,
		'--release',
		'--locked',
	],
	{ cwd: engineDir, env }
)

const archive = path.join(
	cargoTargetDir,
	config.rustTarget,
	'release',
	'libdashbeam_ohos_bridge.a'
)
if (!fs.existsSync(archive)) {
	fail(`Cargo completed without producing ${archive}`)
}

console.log(`OHOS Rust engine archive written to ${archive}`)
