//
//  roundtrip.test.ts
//
//  THE DRIFT ALARM. Every shipped `.mary` must survive parse -> prettyEncode
//  byte-for-byte, and its stored digest must reproduce. If anyone adds a field
//  to the Swift schema and reseals the packages, this goes red and says the
//  workshop is stale. It is the only durable defence against the TypeScript
//  view of the format drifting away from the Swift types.
//

import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { canonicalEncode, digestOf, parsePackage, prettyEncode, seal, verify } from '../src/model/codec'
import type { JsonObject } from '../src/model/codec'

const ABILITIES = join(import.meta.dirname, '..', '..', 'Abilities')

const files = readdirSync(ABILITIES)
  .filter((name) => name.endsWith('.mary'))
  .sort()

describe('shipped ability packages', () => {
  it('finds the shipped corpus', () => {
    expect(files.length).toBeGreaterThan(0)
  })

  describe.each(files)('%s', (name) => {
    const raw = readFileSync(join(ABILITIES, name), 'utf8')

    it('re-serializes byte-for-byte', () => {
      expect(prettyEncode(parsePackage(raw))).toBe(raw)
    })

    it('reproduces its integrity digest', async () => {
      const pkg = parsePackage(raw)
      const integrity = pkg.integrity as JsonObject | undefined
      if (integrity?.digest === undefined) return
      expect(await digestOf(pkg)).toBe(integrity.digest)
    })

    it('verifies', async () => {
      await expect(verify(parsePackage(raw))).resolves.toBeUndefined()
    })

    it('is named for its package id', () => {
      const pkg = parsePackage(raw)
      const meta = pkg.package as JsonObject
      expect(`${String(meta.id)}.mary`).toBe(name)
    })

    it('stays sealed through a re-seal', async () => {
      const pkg = parsePackage(raw)
      expect(prettyEncode(await seal(pkg))).toBe(raw)
    })
  })
})

describe('canonicalEncode', () => {
  it('sorts keys and emits no whitespace', () => {
    expect(canonicalEncode({ b: 1, a: [/* empty */] })).toBe('{"a":[],"b":1}')
  })
})

describe('prettyEncode', () => {
  it('renders an empty array the way Swift does', () => {
    expect(prettyEncode({ a: [] })).toBe('{\n  "a" : [\n\n  ]\n}\n')
  })

  it('renders an empty object the way Swift does', () => {
    expect(prettyEncode({ a: {} })).toBe('{\n  "a" : {\n\n  }\n}\n')
  })

  it('does not escape slashes', () => {
    expect(prettyEncode({ a: 'x/y' })).toBe('{\n  "a" : "x/y"\n}\n')
  })
})
