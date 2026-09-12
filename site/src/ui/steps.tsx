import type { JsonObject, JsonValue } from '../model/codec'
import { getIn } from '../model/path'
import { edit, transform } from '../state/store'
import type { IssueIndex } from './issues'
import { ChipEditor, Field, LineEditor, SelectField, TextField } from './fields'

const DISCIPLINES = [
  { id: 'coding', label: 'Coding — code, projects, build output' },
  { id: 'writing', label: 'Writing — prose, documents, drafts' },
  { id: 'browsing', label: 'Browsing — pages, tabs, the web' },
  { id: 'multimedia', label: 'Multimedia — playback, images, sound' },
  { id: 'awareness', label: 'Awareness — reading what is on screen' },
  { id: 'window-management', label: 'Window Management — moving and arranging windows' },
]

const INTENTS = ['operate', 'perceive', 'compose', 'ask', 'converse']

const GUARDRAIL_CATEGORIES = [
  { id: 'domainMismatch', label: 'Wrong surface kind' },
  { id: 'unscopedTarget', label: 'Only the named target' },
  { id: 'staleState', label: 'Read it live' },
  { id: 'noFocusSteal', label: "Don't steal focus" },
  { id: 'nativeCommandOnly', label: "The app's own command" },
  { id: 'irreversibleAction', label: 'Cannot be undone' },
]

const str = (doc: JsonObject, path: string) => {
  const value = getIn(doc, path)
  return typeof value === 'string' ? value : ''
}
const list = (doc: JsonObject, path: string): string[] => {
  const value = getIn(doc, path)
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === 'string') : []
}
const obj = (doc: JsonObject, path: string): JsonObject => {
  const value = getIn(doc, path)
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as JsonObject) : {}
}
const arr = (doc: JsonObject, path: string): JsonValue[] => {
  const value = getIn(doc, path)
  return Array.isArray(value) ? value : []
}

export interface StepProps {
  doc: JsonObject
  issues: IssueIndex
}

export interface Step {
  id: string
  title: string
  lede: string
  /** Paths this step owns, for the rail badge. */
  scope: string[]
  render: (props: StepProps) => JSX.Element
}

// ── identity ────────────────────────────────────────────────────────────

function Identity({ doc, issues }: StepProps) {
  return (
    <>
      <TextField
        label="Name"
        value={str(doc, 'ability.title')}
        issues={issues.at('ability.title')}
        onCommit={(v) => edit('ability.title', v, true)}
        hint="How you would say it out loud."
      />
      <TextField
        label="Identifier"
        value={str(doc, 'package.id')}
        issues={[...issues.at('package.id'), ...issues.at('ability.id')]}
        mono
        onCommit={(value) =>
          transform('rename', (d) => {
            // package.id and ability.id must match, so they move together.
            const next = { ...d }
            next.package = { ...obj(d, 'package'), id: value }
            next.ability = { ...obj(d, 'ability'), id: value }
            return next
          })
        }
        hint="The filename and the namespace every skill lives under. Lower-case letters, numbers, dots and hyphens."
      />
      <div className="row">
        <TextField
          label="Version"
          value={str(doc, 'package.version')}
          issues={[...issues.at('package.version'), ...issues.at('ability.version')]}
          mono
          onCommit={(value) =>
            transform('version', (d) => ({
              ...d,
              package: { ...obj(d, 'package'), version: value },
              ability: { ...obj(d, 'ability'), version: value },
            }))
          }
        />
        <TextField
          label="Publisher"
          value={str(doc, 'package.publisher')}
          issues={issues.at('package.publisher')}
          onCommit={(v) => edit('package.publisher', v, true)}
        />
      </div>
      <TextField
        label="Summary"
        multiline
        value={str(doc, 'ability.summary')}
        issues={issues.at('ability.summary')}
        onCommit={(v) => edit('ability.summary', v, true)}
        hint="Shown in the inspector. Never interpolated into a prompt — an imported package cannot instruct Mary."
      />
      <Field label="Tint" issues={issues.at('ability.tint')}>
        <div className="list-row">
          <input
            type="text"
            value={str(doc, 'ability.tint')}
            style={{ fontFamily: 'var(--mono)' }}
            onChange={(e) => edit('ability.tint', e.target.value, true)}
          />
          <input
            type="color"
            aria-label="Pick tint"
            value={/^#[0-9a-fA-F]{6}$/.test(str(doc, 'ability.tint')) ? str(doc, 'ability.tint') : '#3b7dd8'}
            onChange={(e) => edit('ability.tint', e.target.value.toUpperCase(), true)}
            style={{ width: 44, padding: 2, flex: 'none' }}
          />
        </div>
      </Field>
    </>
  )
}

// ── extends ─────────────────────────────────────────────────────────────

function Extends({ doc, issues }: StepProps) {
  const dependencies = arr(doc, 'dependencies').map((d) => d as JsonObject)
  const selected = new Set(dependencies.map((d) => String(d.packageID)))

  const toggle = (id: string) => {
    transform('dependencies', (d) => {
      const current = arr(d, 'dependencies').map((x) => x as JsonObject)
      const next = selected.has(id)
        ? current.filter((x) => String(x.packageID) !== id)
        : [...current, { packageID: id, minimumVersion: '1.0.0', optional: false }]
      next.sort((a, b) => String(a.packageID).localeCompare(String(b.packageID)))
      return { ...d, dependencies: next as JsonValue[] }
    })
  }

  return (
    <>
      <p className="muted">
        A discipline is the verb and your application joins it. That is why "read the selection"
        reaches Xcode and Scrivener through the same skill.
      </p>
      <Field label="Extends" issues={issues.at('ability.paradigm')}>
        {DISCIPLINES.map((discipline) => (
          <label
            key={discipline.id}
            style={{ display: 'flex', gap: 8, alignItems: 'center', padding: '4px 0', fontSize: 13 }}
          >
            <input
              type="checkbox"
              checked={selected.has(discipline.id)}
              onChange={() => toggle(discipline.id)}
              style={{ width: 'auto' }}
            />
            {discipline.label}
          </label>
        ))}
      </Field>
      <div className="why">
        <strong>Why this matters.</strong> An application expertise with no discipline behind it
        validates, but it sits inert — there is no craft for it to lend its surface to. Mary's own{' '}
        <code>calendar</code> and <code>reminders</code> packages carry exactly this warning today.
      </div>
    </>
  )
}

// ── vocabulary ──────────────────────────────────────────────────────────

function Vocabulary({ doc, issues }: StepProps) {
  return (
    <>
      <ChipEditor
        label="Listens for"
        values={list(doc, 'ability.triggers.tokens')}
        issues={issues.under('ability.triggers.tokens')}
        onChange={(v) => edit('ability.triggers.tokens', v)}
        placeholder="obsidian"
        hint="Single words. One word per token."
      />
      <ChipEditor
        label="Phrases"
        values={list(doc, 'ability.triggers.phrases')}
        issues={issues.under('ability.triggers.phrases')}
        onChange={(v) => edit('ability.triggers.phrases', v)}
        placeholder="in my notes"
      />
      <ChipEditor
        label="Also called"
        values={list(doc, 'ability.aliases')}
        issues={issues.under('ability.aliases')}
        onChange={(v) => edit('ability.aliases', v)}
        placeholder="the notes app"
      />
      <ChipEditor
        label="Not when"
        values={list(doc, 'ability.triggers.negativeTokens')}
        issues={issues.under('ability.triggers.negativeTokens')}
        onChange={(v) => edit('ability.triggers.negativeTokens', v)}
        placeholder="calendar"
        hint="Words that should steer Mary away from this ability."
      />
    </>
  )
}

// ── sounds like ─────────────────────────────────────────────────────────

function SoundsLike({ doc, issues }: StepProps) {
  const seeds = obj(doc, 'ability.triggers.intentSeeds')
  return (
    <>
      <p className="muted">
        Whole sentences, the way someone would actually say them. These are embedded and compared
        semantically — a bare word belongs in <strong>Listens for</strong>.
      </p>
      {INTENTS.map((intent) => (
        <LineEditor
          key={intent}
          label={intent}
          values={list(doc, `ability.triggers.intentSeeds.${intent}`)}
          issues={issues.under(`ability.triggers.intentSeeds[${intent}]`)}
          placeholder="open my daily note"
          onChange={(values) => {
            // An emptied key is DELETED, never written as []. A declared but
            // empty corpus reads as authored intent and matches nothing.
            const next = { ...seeds }
            if (values.length === 0) delete next[intent]
            else next[intent] = values
            edit('ability.triggers.intentSeeds', next)
          }}
        />
      ))}
    </>
  )
}

// ── house rules ─────────────────────────────────────────────────────────

function HouseRules({ doc, issues }: StepProps) {
  const categories = list(doc, 'ability.operatingPolicy.guardrailCategories')
  return (
    <>
      <Field
        label="Guardrail categories"
        issues={issues.under('ability.operatingPolicy.guardrailCategories')}
        hint="The closed list Mary actually reads when she builds a prompt."
      >
        <div className="chips">
          {GUARDRAIL_CATEGORIES.map((category) => {
            const on = categories.includes(category.id)
            return (
              <button
                key={category.id}
                type="button"
                className="btn btn-sm"
                aria-pressed={on}
                style={
                  on
                    ? { background: 'var(--lp-accent-blue-base)', color: '#fff', borderColor: 'var(--lp-accent-blue-deep)' }
                    : undefined
                }
                onClick={() =>
                  edit(
                    'ability.operatingPolicy.guardrailCategories',
                    on ? categories.filter((c) => c !== category.id) : [...categories, category.id],
                  )
                }
              >
                {category.label}
              </button>
            )
          })}
        </div>
      </Field>
      <LineEditor
        label="Guardrails (prose)"
        values={list(doc, 'ability.operatingPolicy.guardrails')}
        onChange={(v) => edit('ability.operatingPolicy.guardrails', v)}
        hint="Inspector notes for a human reader. Mary reads the categories above, not this text."
      />
      <LineEditor
        label="Phases"
        values={list(doc, 'ability.operatingPolicy.phases')}
        onChange={(v) => edit('ability.operatingPolicy.phases', v)}
      />
      <LineEditor
        label="Success signals"
        values={list(doc, 'ability.operatingPolicy.successSignals')}
        onChange={(v) => edit('ability.operatingPolicy.successSignals', v)}
      />
      <LineEditor
        label="Stop conditions"
        values={list(doc, 'ability.operatingPolicy.stopConditions')}
        onChange={(v) => edit('ability.operatingPolicy.stopConditions', v)}
      />
    </>
  )
}

// ── routing ─────────────────────────────────────────────────────────────

function Routing({ doc, issues }: StepProps) {
  const preference = getIn(doc, 'ability.routing.preference')
  return (
    <>
      <Field
        label="Order"
        hint="A sort key, not a weight. It decides which abilities Mary considers first; evidence settles who wins."
      >
        <input
          type="number"
          value={typeof preference === 'number' ? preference : 0}
          onChange={(e) => edit('ability.routing.preference', Math.trunc(Number(e.target.value)) || 0)}
        />
      </Field>
      <TextField
        label="Competes in"
        mono
        value={str(doc, 'ability.routing.conflictGroup')}
        issues={issues.at('ability.routing.conflictGroup')}
        onCommit={(value) =>
          edit('ability.routing.conflictGroup', value === '' ? undefined : value, true)
        }
        hint="Abilities in the same group are alternatives to one another."
      />
      <SelectField
        label="Settled by"
        value={str(doc, 'ability.routing.conflictPolicy') || 'highestEvidence'}
        onChange={(v) => edit('ability.routing.conflictPolicy', v)}
        options={[
          { value: 'highestEvidence', label: 'Highest evidence' },
          { value: 'preferDirectInteraction', label: 'Prefer direct interaction' },
          { value: 'preferFocusedWorkspace', label: 'Prefer the focused workspace' },
          { value: 'askUser', label: 'Ask which was meant' },
          { value: 'abstain', label: 'Abstain' },
        ]}
      />
    </>
  )
}

// ── skills ──────────────────────────────────────────────────────────────

function Skills({ doc, issues }: StepProps) {
  const skills = arr(doc, 'skills').map((s) => s as JsonObject)
  return (
    <>
      <p className="muted">
        Most application abilities have none. Seven of the nine that ship with Mary declare zero
        skills — they are vocabulary, policy and routing, and they lend their surface to a
        discipline's skills instead.
      </p>
      {skills.length === 0 ? (
        <div className="well tiny muted">No skills. That is the common and usually correct shape.</div>
      ) : (
        skills.map((skill, index) => (
          <div className="card" key={String(skill.id) || index}>
            <div className="kv" style={{ marginBottom: 10 }}>
              <dt>id</dt>
              <dd>{String(skill.id)}</dd>
            </div>
            <TextField
              label="Title"
              value={String(skill.title ?? '')}
              issues={issues.at(`skills[${index}].title`)}
              onCommit={(v) => edit(`skills[${index}].title`, v, true)}
            />
            <TextField
              label="Summary"
              multiline
              value={String(skill.summary ?? '')}
              issues={issues.at(`skills[${index}].summary`)}
              onCommit={(v) => edit(`skills[${index}].summary`, v, true)}
            />
            {issues.under(`skills[${index}]`).length > 0 ? (
              <div className="tiny muted">
                {issues.under(`skills[${index}]`).length} note(s) on this skill — see the panel below.
              </div>
            ) : null}
          </div>
        ))
      )}
      <div className="why">
        <strong>Hands are authored in Mary.</strong> The key presses and typing a skill performs are
        recorded against a live accessibility tree, with the application running. That is Mary's own
        Ability Studio. This workshop keeps any recipe it finds exactly as it is.
      </div>
    </>
  )
}

// ── fixtures ────────────────────────────────────────────────────────────

function slugify(value: string): string {
  return value.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean).join('-').slice(0, 60)
}

function Fixtures({ doc, issues }: StepProps) {
  const fixtures = arr(doc, 'fixtures').map((f) => f as JsonObject)
  const skillIDs = arr(doc, 'skills').map((s) => String((s as JsonObject).id))

  const add = () =>
    transform('add fixture', (d) => {
      const current = arr(d, 'fixtures')
      const used = new Set(current.map((f) => String((f as JsonObject).id)))
      let id = 'new-sentence'
      let n = 2
      while (used.has(id)) id = `new-sentence-${n++}`
      return {
        ...d,
        fixtures: [
          ...current,
          { id, utterance: '', interactions: [], expectedDisposition: 'route' },
        ] as JsonValue[],
      }
    })

  return (
    <>
      <div className="why" style={{ marginTop: 0, marginBottom: 14 }}>
        <strong>This is the lever that moves skill routing.</strong> Phrases above only move the
        ability tier — they cannot separate two skills inside one ability. A <code>route</code>{' '}
        fixture is both the lesson and the exam. One sentence teaches only itself, so give a new
        phrasing three or four siblings.
      </div>
      {fixtures.map((fixture, index) => (
        <div className="card" key={index}>
          <TextField
            label="Someone says"
            value={String(fixture.utterance ?? '')}
            issues={issues.at(`fixtures[${index}].utterance`)}
            onCommit={(value) =>
              transform('fixture', (d) => {
                const list = [...arr(d, 'fixtures')]
                const current: JsonObject = { ...(list[index] as JsonObject), utterance: value }
                if (!String(current.id ?? '').trim() || String(current.id).startsWith('new-sentence'))
                  current.id = slugify(value) || 'new-sentence'
                list[index] = current
                return { ...d, fixtures: list }
              })
            }
            hint="Use {application} if the sentence should name whichever app Mary is pointed at."
          />
          <div className="row">
            <SelectField
              label="Should"
              value={String(fixture.expectedDisposition ?? 'route')}
              onChange={(v) => edit(`fixtures[${index}].expectedDisposition`, v)}
              options={[
                { value: 'route', label: 'Reach a skill — and teach the corpus' },
                { value: 'probe', label: 'Reach a skill — graded only, never taught' },
                { value: 'abstain', label: 'Reach no skill at all' },
                { value: 'ask-user', label: 'Ask which was meant' },
              ]}
            />
            <SelectField
              label="Expected skill"
              value={String(fixture.expectedSkill ?? '')}
              issues={issues.at(`fixtures[${index}].expectedSkill`)}
              onChange={(v) =>
                edit(`fixtures[${index}].expectedSkill`, v === '' ? undefined : v)
              }
              options={[{ value: '', label: '— none —' }, ...skillIDs.map((id) => ({ value: id, label: id }))]}
            />
          </div>
          <button
            type="button"
            className="btn btn-sm"
            onClick={() =>
              transform('remove fixture', (d) => ({
                ...d,
                fixtures: arr(d, 'fixtures').filter((_, i) => i !== index),
              }))
            }
          >
            Remove
          </button>
        </div>
      ))}
      <button type="button" className="btn" onClick={add} style={{ marginTop: 10 }}>
        Add a sentence
      </button>
    </>
  )
}

export const STEPS: Step[] = [
  { id: 'identity', title: 'Identity', lede: 'What it is called, and what it is.', scope: ['package', 'ability.id', 'ability.title', 'ability.summary', 'ability.tint', 'ability.version'], render: Identity },
  { id: 'extends', title: 'What it extends', lede: 'The craft your application joins.', scope: ['dependencies', 'ability.paradigm'], render: Extends },
  { id: 'vocabulary', title: 'What Mary listens for', lede: 'The words that bring this ability into the running.', scope: ['ability.aliases', 'ability.triggers.tokens', 'ability.triggers.phrases', 'ability.triggers.negativeTokens'], render: Vocabulary },
  { id: 'sounds-like', title: 'Sounds like', lede: 'Whole sentences, matched by meaning rather than spelling.', scope: ['ability.triggers.intentSeeds', 'ability.triggers.seedFamilies'], render: SoundsLike },
  { id: 'house-rules', title: 'House rules', lede: 'What Mary must not do while she is here.', scope: ['ability.operatingPolicy'], render: HouseRules },
  { id: 'routing', title: 'How it competes', lede: 'What happens when more than one ability could answer.', scope: ['ability.routing'], render: Routing },
  { id: 'skills', title: 'Skills', lede: 'What this ability can actually do.', scope: ['skills', 'ability.skills'], render: Skills },
  { id: 'fixtures', title: 'Try it out', lede: 'Sentences that teach and grade the router.', scope: ['fixtures'], render: Fixtures },
]
