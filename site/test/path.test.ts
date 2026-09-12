import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { parsePackage, prettyEncode } from '../src/model/codec'
import type { JsonValue } from '../src/model/codec'
import { deleteIn, formatPath, getIn, parsePath, sanitizeText, setIn } from '../src/model/path'

const ABILITIES = join(import.meta.dirname, '..', '..', 'Abilities')
const files = readdirSync(ABILITIES).filter((n) => n.endsWith('.mary')).sort()

function scalarPaths(node: JsonValue, prefix: string[] = [], out: string[][] = []): string[][] {
  if (node === null || typeof node !== 'object') {
    out.push([...prefix])
    return out
  }
  if (Array.isArray(node)) {
    node.forEach((item, i) => scalarPaths(item, [...prefix, String(i)], out))
    return out
  }
  for (const key of Object.keys(node)) scalarPaths(node[key], [...prefix, key], out)
  return out
}

describe('path round-trip', () => {
  it('parses and formats', () => {
    expect(parsePath('ability.triggers.tokens[3]')).toEqual(['ability', 'triggers', 'tokens', 3])
    expect(formatPath(['ability', 'triggers', 'tokens', 3])).toBe('ability.triggers.tokens[3]')
  })
})

describe('setIn is non-destructive', () => {
  // THE ANTI-HYDRATION TEST. Writing a scalar back over itself must leave the
  // document byte-identical. If anything ever materialises a default on the way
  // through, this is what catches it.
  it.each(files)('%s survives a no-op write of every scalar', (name) => {
    const raw = readFileSync(join(ABILITIES, name), 'utf8')
    const doc = parsePackage(raw)
    for (const segments of scalarPaths(doc)) {
      const path = segments.map((s) => (/^\d+$/.test(s) ? Number(s) : s))
      const current = getIn(doc, path)
      expect(prettyEncode(setIn(doc, path, current as JsonValue))).toBe(raw)
    }
  })

  it('keeps untouched subtrees referentially identical', () => {
    const doc = parsePackage(readFileSync(join(ABILITIES, 'safari.mary'), 'utf8'))
    const next = setIn(doc, 'package.publisher', 'Someone Else')
    expect(next.ability).toBe(doc.ability)
    expect(next.plugin).toBe(doc.plugin)
    expect(next.package).not.toBe(doc.package)
  })

  it('deletes a key without disturbing siblings', () => {
    const doc = parsePackage(readFileSync(join(ABILITIES, 'safari.mary'), 'utf8'))
    const next = deleteIn(doc, 'integrity')
    expect(next.integrity).toBeUndefined()
    expect(next.ability).toBe(doc.ability)
  })
})

describe('sanitizeText', () => {
  it('strips lone surrogates that Swift would refuse', () => {
    expect(sanitizeText('ok\uD800here')).toBe('okhere')
    expect(sanitizeText('keep \u{1F600} pairs')).toBe('keep \u{1F600} pairs')
  })
})
