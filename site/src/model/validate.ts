//
//  validate.ts
//  Ability Workshop
//
//  WHAT: Admission checks for one `.mary`, emitting the SAME {severity, code,
//        path, message} shape the Swift validator emits, so an error read here
//        reads identically in the app.
//  PIN:  Graph-level rules (cross-package uniqueness, dependency cycles) need
//        the whole installed set and are deliberately absent. The app
//        re-validates on import; this is a first opinion, not the last word.
//
//  Mirrors Sources/MaryFoundation/Package/Validation/AbilityPackageValidator.swift
//      and Sources/MaryFoundation/Package/Validation/PackageIssueSink.swift
//

import type { JsonObject, JsonValue } from './codec'
import { CURRENT_FORMAT_VERSION, PACKAGE_FORMAT } from './codec'

export type Severity = 'error' | 'warning'

export interface SchemaIssue {
  severity: Severity
  code: string
  path: string
  message: string
}

/** Operations the runtime owns; a Skill may not claim these names. */
export const RUNTIME_PRIMITIVES = [
  'run_applescript',
  'run_shell',
  'confirm_pending_skill',
  'cancel_pending_skill',
]

/** The only placeholder this format fills. */
export const UTTERANCE_SLOTS = ['application']

const MAX_ID_BYTES = 128
const MAX_TERMS = 64
const MAX_TERM_BYTES = 128
const MAX_SENTENCES = 64
const MAX_SENTENCE_BYTES = 240

const utf8 = new TextEncoder()
const byteLength = (value: string) => utf8.encode(value).length

// ─── primitives, mirroring SchemaIdentifierValidation / PackageIssueSink ────

export function isValidIdentifier(value: string): boolean {
  if (value.length === 0) return false
  if (byteLength(value) > MAX_ID_BYTES) return false
  if (!/^[a-z]/.test(value[0].toLowerCase()) || !/^\p{L}/u.test(value)) return false
  if (value !== value.toLowerCase()) return false
  if (value.includes('..')) return false
  if (value.endsWith('.') || value.endsWith('-')) return false
  return /^[a-z0-9.-]+$/.test(value)
}

export function isValidTint(value: string): boolean {
  return /^#[0-9a-fA-F]{6}$/.test(value)
}

/** Mirrors SemanticVersion.Parsed: three numeric core parts, optional pre-release/build. */
export function isValidSemanticVersion(value: string): boolean {
  if (value.length === 0 || byteLength(value) > MAX_ID_BYTES) return false
  if ((value.match(/\+/g) ?? []).length > 1) return false
  const [precedence, build] = splitOnce(value, '+')
  if (precedence.length === 0) return false
  if (build !== undefined && !identifiersAreValid(build, false)) return false
  const [core, prerelease] = splitOnce(precedence, '-')
  const parts = core.split('.')
  if (parts.length !== 3) return false
  if (!parts.every((part) => /^(0|[1-9]\d*)$/.test(part))) return false
  if (prerelease !== undefined && !identifiersAreValid(prerelease, true)) return false
  return true
}

function splitOnce(value: string, separator: string): [string, string | undefined] {
  const index = value.indexOf(separator)
  if (index < 0) return [value, undefined]
  return [value.slice(0, index), value.slice(index + 1)]
}

function identifiersAreValid(text: string, rejectNumericLeadingZeros: boolean): boolean {
  const parts = text.split('.')
  if (parts.length === 0) return false
  return parts.every((part) => {
    if (part.length === 0) return false
    if (!/^[0-9A-Za-z-]+$/.test(part)) return false
    if (rejectNumericLeadingZeros && /^0\d+$/.test(part)) return false
    return true
  })
}

export function isSnakeCase(value: string): boolean {
  return byteLength(value) <= MAX_ID_BYTES && /^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$/.test(value)
}

/** Placeholders in `text` that name no declared slot. */
export function unknownPlaceholders(text: string): string[] {
  const found = text.match(/\{([^}]*)\}/g) ?? []
  const unknown = found.filter((raw) => !UTTERANCE_SLOTS.includes(raw.slice(1, -1)))
  return Array.from(new Set(unknown))
}

// ─── the sink ───────────────────────────────────────────────────────────────

class IssueSink {
  readonly issues: SchemaIssue[] = []

  error(code: string, path: string, message: string) {
    this.issues.push({ severity: 'error', code, path, message })
  }

  warning(code: string, path: string, message: string) {
    this.issues.push({ severity: 'warning', code, path, message })
  }

  checkID(value: unknown, path: string) {
    if (typeof value !== 'string' || !isValidIdentifier(value)) {
      this.error(
        'invalid-id',
        path,
        'Use a lower-case portable identifier containing letters, numbers, dots, or hyphens.',
      )
    }
  }

  checkText(value: unknown, path: string, noun: string) {
    if (typeof value !== 'string' || value.trim().length === 0) {
      this.error(
        `missing-${noun}`,
        path,
        `Every ${noun.replace(/-/g, ' ')} must contain text.`,
      )
    }
  }

  /** Bounded canonical search terms, so empty or punctuation cannot match everything. */
  validateSearchTerms(values: string[], path: string, noun: string, maximumWordsPerTerm = 12) {
    if (values.length > MAX_TERMS) {
      this.error(
        'too-many-routing-terms',
        path,
        `A ${noun} list may contain at most ${MAX_TERMS} terms.`,
      )
    }
    const inspected = values.slice(0, MAX_TERMS)
    if (duplicates(inspected).length > 0) {
      this.error('duplicate-routing-term', path, 'A routing term appears more than once.')
    }
    inspected.forEach((value, index) => {
      const words = value.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean)
      const canonical = words.join(' ')
      if (
        words.length === 0 ||
        words.length > maximumWordsPerTerm ||
        byteLength(value) > MAX_TERM_BYTES ||
        value !== canonical
      ) {
        this.error(
          'invalid-routing-term',
          `${path}[${index}]`,
          `Routing terms use one to ${maximumWordsPerTerm} lower-case words separated by single spaces and at most ${MAX_TERM_BYTES} UTF-8 bytes.`,
        )
      }
    })
  }

  /** SENTENCES, NOT TERMS. These corpora are embedded whole. */
  validateAuthoredSentences(sentences: string[], path: string, noun: string) {
    if (sentences.length === 0) {
      this.warning(
        'empty-authored-corpus',
        path,
        `A declared ${noun} list with no sentences reads as authored and matches nothing.`,
      )
    }
    if (sentences.length > MAX_SENTENCES) {
      this.error('too-many-authored-sentences', path, `At most ${MAX_SENTENCES} ${noun}s per key.`)
    }
    const seen = new Set<string>()
    sentences.slice(0, MAX_SENTENCES).forEach((sentence, index) => {
      const trimmed = sentence.trim()
      const at = `${path}[${index}]`
      if (trimmed.length === 0) {
        this.error('empty-authored-sentence', at, `A ${noun} may not be blank.`)
        return
      }
      if (byteLength(trimmed) > MAX_SENTENCE_BYTES) {
        this.error(
          'authored-sentence-too-long',
          at,
          `A ${noun} may be at most ${MAX_SENTENCE_BYTES} bytes.`,
        )
      }
      if (trimmed.split(/\s+/).length < 2) {
        this.warning(
          'authored-sentence-is-a-word',
          at,
          `"${trimmed}" is one word. This corpus is embedded as sentences; a bare term belongs in triggers.tokens.`,
        )
      }
      if (seen.has(trimmed.toLowerCase())) {
        this.warning(
          'duplicate-authored-sentence',
          at,
          `"${trimmed}" is seeded twice under the same key.`,
        )
      }
      seen.add(trimmed.toLowerCase())
      this.checkPlaceholders(trimmed, at)
    })
  }

  checkPlaceholders(text: string, path: string) {
    const unknown = unknownPlaceholders(text)
    if (unknown.length === 0) return
    const known = UTTERANCE_SLOTS.map((slot) => `{${slot}}`).join(', ')
    this.error(
      'unknown-utterance-placeholder',
      path,
      `${unknown.join(', ')} is not a placeholder this format fills; an unfilled one stays in the sentence and reaches nobody. Available: ${known}.`,
    )
  }
}

function duplicates(values: string[]): string[] {
  const seen = new Set<string>()
  const repeated = new Set<string>()
  for (const value of values) {
    if (seen.has(value)) repeated.add(value)
    seen.add(value)
  }
  return Array.from(repeated)
}

// ─── helpers over the raw tree ──────────────────────────────────────────────

const asObject = (value: JsonValue | undefined): JsonObject =>
  value && typeof value === 'object' && !Array.isArray(value) ? value : {}

const asArray = (value: JsonValue | undefined): JsonValue[] => (Array.isArray(value) ? value : [])

const asStrings = (value: JsonValue | undefined): string[] =>
  asArray(value).filter((item): item is string => typeof item === 'string')

const asString = (value: JsonValue | undefined): string =>
  typeof value === 'string' ? value : ''

// ─── the validator ──────────────────────────────────────────────────────────

export function validatePackage(pkg: JsonObject): SchemaIssue[] {
  const sink = new IssueSink()
  validateIdentity(pkg, sink)
  validateSkills(pkg, sink)
  validateFixtures(pkg, sink)
  validateParadigm(pkg, sink)
  return sink.issues
}

export function hasErrors(issues: SchemaIssue[]): boolean {
  return issues.some((issue) => issue.severity === 'error')
}

function validateIdentity(pkg: JsonObject, sink: IssueSink) {
  if (pkg.format !== PACKAGE_FORMAT) {
    sink.error('unsupported-format', 'format', `Expected ${PACKAGE_FORMAT}.`)
  }
  if (pkg.formatVersion !== CURRENT_FORMAT_VERSION) {
    sink.error(
      'unsupported-format-version',
      'formatVersion',
      `Expected format version ${CURRENT_FORMAT_VERSION}.`,
    )
  }

  const meta = asObject(pkg.package)
  const ability = asObject(pkg.ability)

  sink.checkID(meta.id, 'package.id')
  sink.checkID(ability.id, 'ability.id')
  if (asString(meta.id) !== asString(ability.id)) {
    sink.error(
      'package-ability-mismatch',
      'ability.id',
      'An ability-level package id must match its exported ability id.',
    )
  }
  if (asString(meta.version) !== asString(ability.version)) {
    sink.error(
      'version-mismatch',
      'ability.version',
      'The package and exported ability must have the same version.',
    )
  }

  sink.checkText(meta.publisher, 'package.publisher', 'publisher')
  sink.checkText(meta.summary, 'package.summary', 'package-summary')
  sink.checkText(ability.title, 'ability.title', 'ability-title')
  sink.checkText(ability.summary, 'ability.summary', 'ability-summary')

  if (!isValidSemanticVersion(asString(meta.version))) {
    sink.error(
      'invalid-version',
      'package.version',
      'Use semantic versioning such as 1.0.0 or 1.0.0-beta.1.',
    )
  }
  if (meta.minimumMaryVersion !== undefined && !isValidSemanticVersion(asString(meta.minimumMaryVersion))) {
    sink.error('invalid-version', 'package.minimumMaryVersion', 'Use semantic versioning such as 1.0.0.')
  }
  if (!isValidTint(asString(ability.tint))) {
    sink.error('invalid-tint', 'ability.tint', 'Use a six-digit #RRGGBB color.')
  }

  sink.validateSearchTerms(asStrings(ability.aliases), 'ability.aliases', 'Ability alias')

  const triggers = asObject(ability.triggers)
  sink.validateSearchTerms(asStrings(triggers.tokens), 'ability.triggers.tokens', 'trigger token', 1)
  sink.validateSearchTerms(asStrings(triggers.phrases), 'ability.triggers.phrases', 'trigger phrase')
  sink.validateSearchTerms(
    asStrings(triggers.negativeTokens),
    'ability.triggers.negativeTokens',
    'negative trigger',
  )
  asStrings(triggers.phrases).forEach((phrase, index) =>
    sink.checkPlaceholders(phrase, `ability.triggers.phrases[${index}]`),
  )
  asStrings(triggers.tokens).forEach((token, index) =>
    sink.checkPlaceholders(token, `ability.triggers.tokens[${index}]`),
  )

  const intentAliases = asStrings(triggers.intentAliases)
  if (intentAliases.length > MAX_TERMS) {
    sink.error(
      'too-many-intent-aliases',
      'ability.triggers.intentAliases',
      'An Ability may declare at most 64 intent aliases.',
    )
  }
  const inspectedAliases = intentAliases.slice(0, MAX_TERMS)
  if (duplicates(inspectedAliases).length > 0) {
    sink.error(
      'duplicate-intent-alias',
      'ability.triggers.intentAliases',
      'An intent alias appears more than once.',
    )
  }
  inspectedAliases.forEach((alias, index) =>
    sink.checkID(alias, `ability.triggers.intentAliases[${index}]`),
  )

  const intentSeeds = asObject(triggers.intentSeeds)
  for (const key of Object.keys(intentSeeds).sort()) {
    sink.validateAuthoredSentences(
      asStrings(intentSeeds[key]),
      `ability.triggers.intentSeeds[${key}]`,
      'intent seed',
    )
  }

  const seedFamilies = asObject(triggers.seedFamilies)
  for (const key of Object.keys(seedFamilies).sort()) {
    sink.checkID(key, 'ability.triggers.seedFamilies key')
    sink.validateAuthoredSentences(
      asStrings(seedFamilies[key]),
      `ability.triggers.seedFamilies[${key}]`,
      'seed sentence',
    )
  }
  if (Object.keys(seedFamilies).length > 8) {
    sink.error(
      'too-many-seed-families',
      'ability.triggers.seedFamilies',
      'An Ability may declare at most 8 seed families.',
    )
  }

  duplicates(asStrings(ability.skills)).forEach((id) =>
    sink.error(
      'duplicate-ability-skill',
      'ability.skills',
      `Skill id ${id} appears more than once in the Ability schema.`,
    ),
  )
  duplicates(asStrings(ability.threadProjections)).forEach((id) =>
    sink.error(
      'duplicate-ability-projection',
      'ability.threadProjections',
      `Projection id ${id} appears more than once in the Ability schema.`,
    ),
  )

  const policy = asObject(ability.operatingPolicy)
  duplicates(asStrings(policy.guardrailCategories)).forEach((value) =>
    sink.error(
      'duplicate-ability-guardrail-category',
      'ability.operatingPolicy.guardrailCategories',
      `Guardrail category ${value} appears more than once.`,
    ),
  )

  const dependencies = asArray(pkg.dependencies).map(asObject)
  duplicates(dependencies.map((d) => asString(d.packageID))).forEach((id) =>
    sink.error('duplicate-dependency', 'dependencies', `Package dependency ${id} appears more than once.`),
  )
  dependencies.forEach((dependency, index) => {
    sink.checkID(dependency.packageID, `dependencies[${index}].packageID`)
    if (asString(dependency.packageID) === asString(meta.id)) {
      sink.error('self-dependency', `dependencies[${index}]`, 'An Ability package cannot depend on itself.')
    }
    if (!isValidSemanticVersion(asString(dependency.minimumVersion))) {
      sink.error(
        'invalid-version',
        `dependencies[${index}].minimumVersion`,
        'Use semantic versioning such as 1.0.0.',
      )
    }
  })

  const routing = asObject(ability.routing)
  const conflictGroup = routing.conflictGroup
  if (typeof conflictGroup === 'string' && conflictGroup.length > 0 && !isValidIdentifier(conflictGroup)) {
    sink.error(
      'invalid-conflict-group',
      'ability.routing.conflictGroup',
      'Conflict groups use portable lower-case identifiers.',
    )
  }
}

function validateSkills(pkg: JsonObject, sink: IssueSink) {
  const ability = asObject(pkg.ability)
  const abilityID = asString(ability.id)
  const declared = asStrings(ability.skills)
  const schemas = asArray(pkg.skills).map(asObject)
  const schemaIDs = schemas.map((skill) => asString(skill.id))

  for (const id of declared) {
    if (!schemaIDs.includes(id)) {
      sink.error(
        'missing-skill-schema',
        'ability.skills',
        `The Ability exports ${id}, but no Skill schema defines it.`,
      )
    }
  }
  for (const id of schemaIDs) {
    if (!declared.includes(id)) {
      sink.error(
        'orphan-skill-schema',
        'skills',
        `Skill ${id} is defined but the Ability does not export it.`,
      )
    }
  }

  schemas.forEach((skill, index) => {
    const path = `skills[${index}]`
    const id = asString(skill.id)
    sink.checkID(id, `${path}.id`)
    sink.checkText(skill.title, `${path}.title`, 'title')
    sink.checkText(skill.summary, `${path}.summary`, 'summary')
    if (abilityID.length > 0 && id.length > 0 && !id.startsWith(`${abilityID}.`)) {
      sink.error(
        'skill-outside-namespace',
        `${path}.id`,
        `A Skill id must begin with "${abilityID}." so it lives inside the Ability that exports it.`,
      )
    }
    if (!isValidSemanticVersion(asString(skill.version))) {
      sink.error('invalid-version', `${path}.version`, 'Use semantic versioning such as 1.0.0.')
    }
    const timeout = skill.timeoutSeconds
    if (timeout !== undefined && (typeof timeout !== 'number' || !Number.isFinite(timeout) || timeout <= 0)) {
      sink.error(
        'invalid-timeout',
        `${path}.timeoutSeconds`,
        'A Skill timeout must be a finite number of seconds greater than zero.',
      )
    }

    const exposure = asObject(skill.modelExposure)
    const enabled = exposure.enabled !== false
    if (enabled) {
      const explicit = asString(exposure.invocationName)
      const bindings = asArray(asObject(skill.execution).bindings).map(asObject)
      const best = [...bindings].sort(
        (a, b) => Number(b.preference ?? 0) - Number(a.preference ?? 0),
      )[0]
      const resolved = explicit.length > 0 ? explicit : asString(best?.operation)
      if (resolved.length === 0) {
        sink.error(
          'missing-invocation-name',
          `${path}.modelExposure.invocationName`,
          'A model-exposed Skill needs an invocation name, or a binding to take one from.',
        )
      } else {
        if (!isSnakeCase(resolved)) {
          sink.error(
            'invalid-invocation-name',
            `${path}.modelExposure.invocationName`,
            'An invocation name is lower_snake_case.',
          )
        }
        if (RUNTIME_PRIMITIVES.includes(resolved)) {
          sink.error(
            'reserved-invocation-name',
            `${path}.modelExposure.invocationName`,
            `${resolved} is a runtime primitive and cannot be claimed by a Skill.`,
          )
        }
      }
    }
  })
}

function validateFixtures(pkg: JsonObject, sink: IssueSink) {
  const fixtures = asArray(pkg.fixtures).map(asObject)
  const ownSkills = new Set(asArray(pkg.skills).map((s) => asString(asObject(s).id)))

  duplicates(fixtures.map((f) => asString(f.id))).forEach((id) =>
    sink.error('duplicate-fixture', 'fixtures', `Fixture id ${id} appears more than once.`),
  )

  fixtures.forEach((fixture, index) => {
    const path = `fixtures[${index}]`
    sink.checkText(fixture.id, `${path}.id`, 'fixture-id')
    sink.checkText(fixture.utterance, `${path}.utterance`, 'utterance')
    sink.checkPlaceholders(asString(fixture.utterance), `${path}.utterance`)

    const disposition = asString(fixture.expectedDisposition)
    if (!['route', 'probe', 'abstain', 'ask-user'].includes(disposition)) {
      sink.error(
        'unknown-fixture-disposition',
        `${path}.expectedDisposition`,
        'A fixture is one of route, probe, abstain, or ask-user.',
      )
    }
    const expected = asString(fixture.expectedSkill)
    if (disposition === 'probe' && expected.length === 0) {
      sink.error(
        'probe-without-skill',
        `${path}.expectedSkill`,
        'A probe fixture is an exam; it must name the Skill it expects to reach.',
      )
    }
    if ((disposition === 'route' || disposition === 'probe') && expected.length > 0) {
      if (!ownSkills.has(expected) && !realizesSkill(pkg, expected)) {
        sink.warning(
          'fixture-skill-not-owned',
          `${path}.expectedSkill`,
          `${expected} is not defined or realized by this package. The app will check this against the whole installed set.`,
        )
      }
    }
  })
}

function realizesSkill(pkg: JsonObject, skillID: string): boolean {
  const plugin = asObject(pkg.plugin)
  return asArray(plugin.realizations)
    .map(asObject)
    .some((realization) => asString(realization.skillID) === skillID)
}

function validateParadigm(pkg: JsonObject, sink: IssueSink) {
  const ability = asObject(pkg.ability)
  const paradigm = asString(ability.paradigm)
  if (paradigm.length === 0) return
  if (!['discipline', 'applicationExpertise', 'systemControl', 'reasoning'].includes(paradigm)) {
    sink.error(
      'unknown-paradigm',
      'ability.paradigm',
      'A paradigm is one of discipline, applicationExpertise, systemControl, or reasoning.',
    )
    return
  }
  if (paradigm === 'applicationExpertise') {
    const dependencies = asArray(pkg.dependencies).map(asObject)
    const hasRequired = dependencies.some((dependency) => dependency.optional !== true)
    if (!hasRequired) {
      sink.warning(
        'paradigm-expertise-without-discipline',
        'ability.paradigm',
        'An application-expertise Ability usually extends a discipline; depend on that discipline package so the two compose.',
      )
    }
  }
}
