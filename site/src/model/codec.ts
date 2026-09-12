//
//  codec.ts
//  Ability Workshop
//
//  WHAT: Read/write `.mary` bytes exactly as Swift's AbilityPackageCodec does.
//  PIN:  Operates on the RAW parsed tree, never a re-materialized typed object.
//        That is what keeps regions we have no editor for byte-identical, and
//        what keeps Swift's deliberate omit-when-false encoders intact.
//
//  Mirrors Sources/MaryFoundation/Package/AbilityPackageCodec.swift
//

export type JsonValue =
  | null
  | boolean
  | number
  | string
  | JsonValue[]
  | { [key: string]: JsonValue }

export type JsonObject = { [key: string]: JsonValue }

/** Import cap. Four MiB, matching AbilityPackageCodec.maximumPackageBytes. */
export const MAXIMUM_PACKAGE_BYTES = 4 * 1024 * 1024

export const PACKAGE_FORMAT = 'mary.ability-package'
export const CURRENT_FORMAT_VERSION = 1

export class CodecError extends Error {
  constructor(readonly code: string, message: string) {
    super(message)
    this.name = 'CodecError'
  }
}

/**
 * Swift `JSONEncoder` with `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`.
 *
 * The quirks are load-bearing and all verified against the seventeen shipped
 * packages: two-space indent, `" : "` between key and value, an empty array or
 * object rendered as a newline, a blank line, then the closing brace at the
 * PARENT indent, and a trailing newline on the whole document.
 */
export function prettyEncode(value: JsonValue): string {
  return encodeValue(value, 0) + '\n'
}

function encodeValue(value: JsonValue, indent: number): string {
  const pad = '  '.repeat(indent)
  const padInner = '  '.repeat(indent + 1)

  if (value === null) return 'null'
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  if (typeof value === 'number') return JSON.stringify(value)
  if (typeof value === 'string') return JSON.stringify(value)

  if (Array.isArray(value)) {
    if (value.length === 0) return `[\n\n${pad}]`
    const body = value.map((item) => padInner + encodeValue(item, indent + 1)).join(',\n')
    return `[\n${body}\n${pad}]`
  }

  const keys = Object.keys(value).sort()
  if (keys.length === 0) return `{\n\n${pad}}`
  const body = keys
    .map((key) => `${padInner}${JSON.stringify(key)} : ${encodeValue(value[key], indent + 1)}`)
    .join(',\n')
  return `{\n${body}\n${pad}}`
}

/** The digest pre-image: compact, sorted keys, no trailing newline. */
export function canonicalEncode(value: JsonValue): string {
  if (value === null) return 'null'
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  if (typeof value === 'number') return JSON.stringify(value)
  if (typeof value === 'string') return JSON.stringify(value)
  if (Array.isArray(value)) return '[' + value.map(canonicalEncode).join(',') + ']'
  return (
    '{' +
    Object.keys(value)
      .sort()
      .map((key) => JSON.stringify(key) + ':' + canonicalEncode(value[key]))
      .join(',') +
    '}'
  )
}

/** SHA-256 over the canonical bytes with `integrity` removed. */
export async function digestOf(pkg: JsonObject): Promise<string> {
  const { integrity: _dropped, ...unsigned } = pkg
  const bytes = new TextEncoder().encode(canonicalEncode(unsigned as JsonValue))
  const hash = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

/**
 * Refresh the digest. Matches `AbilityPackageCodec.encoded`, which always
 * recomputes and DROPS a stale signature — the browser holds no private key,
 * so a signature it carried forward would be a lie.
 */
export async function seal(pkg: JsonObject): Promise<JsonObject> {
  const digest = await digestOf(pkg)
  return { ...pkg, integrity: { algorithm: 'sha256', digest } }
}

export function isSigned(pkg: JsonObject): boolean {
  const integrity = pkg.integrity
  if (!integrity || typeof integrity !== 'object' || Array.isArray(integrity)) return false
  return integrity.publicKey != null && integrity.signature != null
}

/** Verify a digest the way Swift does: absent integrity is not an error. */
export async function verify(pkg: JsonObject): Promise<void> {
  const integrity = pkg.integrity
  if (integrity == null) return
  if (typeof integrity !== 'object' || Array.isArray(integrity)) {
    throw new CodecError('malformedDigest', 'The package integrity block is not an object.')
  }
  const algorithm = integrity.algorithm
  if (typeof algorithm !== 'string' || algorithm.toLowerCase() !== 'sha256') {
    throw new CodecError(
      'unsupportedDigestAlgorithm',
      'Ability packages currently require a SHA-256 digest.',
    )
  }
  const stored = integrity.digest
  if (typeof stored !== 'string' || stored.length !== 64 || !/^[0-9a-fA-F]{64}$/.test(stored)) {
    throw new CodecError(
      'malformedDigest',
      'The package digest must be 64 hexadecimal SHA-256 characters.',
    )
  }
  const expected = await digestOf(pkg)
  if (expected !== stored.toLowerCase()) {
    throw new CodecError('digestMismatch', 'The package digest does not match its contents.')
  }
}

/**
 * Parse `.mary` text. Shape checks only — full admission is `validate.ts`.
 * A signature is NOT verified here; the browser reports it and refuses to edit.
 */
export function parsePackage(text: string): JsonObject {
  if (new TextEncoder().encode(text).length > MAXIMUM_PACKAGE_BYTES) {
    throw new CodecError(
      'packageTooLarge',
      `Ability packages cannot exceed ${MAXIMUM_PACKAGE_BYTES} bytes.`,
    )
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch (error) {
    throw new CodecError('notJSON', `This file is not valid JSON: ${(error as Error).message}`)
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new CodecError('notAPackage', 'A .mary package must be a JSON object.')
  }
  const pkg = parsed as JsonObject
  if (pkg.format !== PACKAGE_FORMAT) {
    throw new CodecError(
      'unsupportedFormat',
      `Expected "format" to be ${PACKAGE_FORMAT}. This does not look like a Mary ability package.`,
    )
  }
  if (pkg.formatVersion !== CURRENT_FORMAT_VERSION) {
    throw new CodecError(
      'unsupportedFormatVersion',
      `Expected format version ${CURRENT_FORMAT_VERSION}, found ${String(pkg.formatVersion)}.`,
    )
  }
  return pkg
}
