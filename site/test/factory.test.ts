import { writeFileSync, mkdirSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { prettyEncode, seal, parsePackage } from '../src/model/codec'
import { createNativeApplicationPackage } from '../src/model/factory'
import { hasErrors, validatePackage } from '../src/model/validate'

const template = {
  packageID: 'obsidian',
  title: 'Obsidian',
  bundleIdentifier: 'md.obsidian',
  bundleName: 'Obsidian.app',
  publisher: 'Ability Workshop',
  tint: '#7C3AED',
  disciplines: ['writing'],
}

describe('factory', () => {
  it('mints a package with no validation errors', () => {
    const issues = validatePackage(createNativeApplicationPackage(template))
    expect(issues.filter((i) => i.severity === 'error')).toEqual([])
    expect(hasErrors(issues)).toBe(false)
  })

  it('round-trips through the codec', async () => {
    const sealed = await seal(createNativeApplicationPackage(template))
    const text = prettyEncode(sealed)
    expect(prettyEncode(parsePackage(text))).toBe(text)
  })

  it('emits a sample for the Swift probe', async () => {
    const out = process.env.SAMPLE_OUT
    if (!out) return
    mkdirSync(out, { recursive: true })
    writeFileSync(`${out}/obsidian.mary`, prettyEncode(await seal(createNativeApplicationPackage(template))))
  })
})
