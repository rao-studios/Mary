//
//  sync-abilities.mjs
//
//  WHAT: Copy the shipped Abilities/*.mary into public/templates/ with an index,
//        so the workshop can offer them as starting points.
//  PIN:  Copied verbatim. They are lazy-fetched, never bundled — coding.mary is
//        109 KB on its own and nobody needs it before they ask for it.
//

import { copyFileSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const abilities = join(here, '..', '..', 'Abilities')
const out = join(here, '..', 'public', 'templates')

rmSync(out, { recursive: true, force: true })
mkdirSync(out, { recursive: true })

const index = []
for (const name of readdirSync(abilities).filter((n) => n.endsWith('.mary')).sort()) {
  const source = join(abilities, name)
  const raw = readFileSync(source, 'utf8')
  const pkg = JSON.parse(raw)
  copyFileSync(source, join(out, name))
  index.push({
    file: name,
    id: pkg.package.id,
    title: pkg.ability.title,
    summary: pkg.ability.summary,
    tint: pkg.ability.tint,
    paradigm: pkg.ability.paradigm ?? null,
    skills: pkg.skills.length,
    fixtures: pkg.fixtures.length,
    operations: pkg.plugin?.operations?.length ?? 0,
    hasPlugin: pkg.plugin != null,
    bytes: Buffer.byteLength(raw, 'utf8'),
  })
}

writeFileSync(join(out, 'index.json'), JSON.stringify(index, null, 2) + '\n')
console.log(`synced ${index.length} ability packages -> public/templates/`)
