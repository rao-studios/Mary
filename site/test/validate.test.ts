import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { parsePackage } from '../src/model/codec'
import { hasErrors, validatePackage } from '../src/model/validate'

const ABILITIES = join(import.meta.dirname, '..', '..', 'Abilities')
const files = readdirSync(ABILITIES).filter((n) => n.endsWith('.mary')).sort()

describe('shipped packages validate', () => {
  it.each(files)('%s has no errors', (name) => {
    const issues = validatePackage(parsePackage(readFileSync(join(ABILITIES, name), 'utf8')))
    const errors = issues.filter((i) => i.severity === 'error')
    expect(errors).toEqual([])
    expect(hasErrors(issues)).toBe(false)
  })

  it('agrees with mary-package-probe on which packages warn', () => {
    const warned = files.filter((name) =>
      validatePackage(parsePackage(readFileSync(join(ABILITIES, name), 'utf8')))
        .some((i) => i.code === 'paradigm-expertise-without-discipline'),
    )
    // mary-package-probe check reports exactly these two.
    expect(warned).toEqual(['calendar.mary', 'reminders.mary'])
  })
})
