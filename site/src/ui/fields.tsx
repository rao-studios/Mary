import { useEffect, useId, useState } from 'react'
import type { ReactNode } from 'react'
import type { SchemaIssue } from '../model/validate'
import { sanitizeText } from '../model/path'

export function IssueList({ issues }: { issues: SchemaIssue[] }) {
  if (issues.length === 0) return null
  return (
    <>
      {issues.map((issue, index) => (
        <p key={index} className={`issue-inline ${issue.severity}`}>
          {issue.message} <code>{issue.code}</code>
        </p>
      ))}
    </>
  )
}

export function Field({
  label,
  hint,
  issues = [],
  children,
}: {
  label: string
  hint?: ReactNode
  issues?: SchemaIssue[]
  children: ReactNode
}) {
  const bad = issues.some((i) => i.severity === 'error')
  return (
    <div className={`field${bad ? ' invalid' : ''}`}>
      <label>{label}</label>
      {children}
      {hint ? <p className="hint">{hint}</p> : null}
      <IssueList issues={issues} />
    </div>
  )
}

/** Local state while typing; commits on idle or blur so validation never fights the keyboard. */
export function TextField({
  label,
  hint,
  issues,
  value,
  onCommit,
  multiline,
  placeholder,
  mono,
}: {
  label: string
  hint?: ReactNode
  issues?: SchemaIssue[]
  value: string
  onCommit: (value: string) => void
  multiline?: boolean
  placeholder?: string
  mono?: boolean
}) {
  const [draft, setDraft] = useState(value)
  useEffect(() => setDraft(value), [value])

  useEffect(() => {
    if (draft === value) return
    const timer = setTimeout(() => onCommit(sanitizeText(draft)), 160)
    return () => clearTimeout(timer)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draft])

  const props = {
    value: draft,
    placeholder,
    style: mono ? { fontFamily: 'var(--mono)' } : undefined,
    onChange: (e: { target: { value: string } }) => setDraft(e.target.value),
    onBlur: () => onCommit(sanitizeText(draft)),
  }
  return (
    <Field label={label} hint={hint} issues={issues}>
      {multiline ? <textarea {...props} /> : <input type="text" {...props} />}
    </Field>
  )
}

export function SelectField({
  label,
  hint,
  issues,
  value,
  options,
  onChange,
}: {
  label: string
  hint?: ReactNode
  issues?: SchemaIssue[]
  value: string
  options: { value: string; label: string }[]
  onChange: (value: string) => void
}) {
  return (
    <Field label={label} hint={hint} issues={issues}>
      <select value={value} onChange={(e) => onChange(e.target.value)}>
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </Field>
  )
}

/**
 * Terms are canonical or they are an error, so show the canonical form while
 * the user types and let one tap fix it. Prevention beats a red message.
 */
export function canonicalTerm(value: string): string {
  return value
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter(Boolean)
    .join(' ')
}

export function ChipEditor({
  label,
  hint,
  issues = [],
  values,
  onChange,
  placeholder,
  canonical = true,
}: {
  label: string
  hint?: ReactNode
  issues?: SchemaIssue[]
  values: string[]
  onChange: (values: string[]) => void
  placeholder?: string
  canonical?: boolean
}) {
  const [draft, setDraft] = useState('')
  const id = useId()

  const add = () => {
    const raw = sanitizeText(draft.trim())
    if (raw === '') return
    const next = canonical ? canonicalTerm(raw) : raw
    if (next !== '' && !values.includes(next)) onChange([...values, next])
    setDraft('')
  }

  const preview = canonical && draft.trim() !== '' ? canonicalTerm(draft.trim()) : ''
  const drift = preview !== '' && preview !== draft.trim()

  return (
    <Field label={label} hint={hint} issues={issues}>
      {values.length > 0 ? (
        <div className="chips">
          {values.map((value, index) => {
            const bad = issues.some((i) => i.path.endsWith(`[${index}]`) && i.severity === 'error')
            return (
              <span key={`${value}-${index}`} className={`chip${bad ? ' bad' : ''}`}>
                {value}
                <button
                  type="button"
                  aria-label={`Remove ${value}`}
                  onClick={() => onChange(values.filter((_, i) => i !== index))}
                >
                  ×
                </button>
              </span>
            )
          })}
        </div>
      ) : null}
      <div className="list-row">
        <input
          id={id}
          type="text"
          value={draft}
          placeholder={placeholder}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault()
              add()
            }
          }}
        />
        <button type="button" className="btn btn-sm" onClick={add} disabled={draft.trim() === ''}>
          Add
        </button>
      </div>
      {drift ? (
        <p className="hint">
          Will be added as <code>{preview}</code> — terms are lower-case words separated by single
          spaces.
        </p>
      ) : null}
    </Field>
  )
}

/** Free prose lines: guardrails, phases, seeds. No canonical form, order matters. */
export function LineEditor({
  label,
  hint,
  issues = [],
  values,
  onChange,
  placeholder,
}: {
  label: string
  hint?: ReactNode
  issues?: SchemaIssue[]
  values: string[]
  onChange: (values: string[]) => void
  placeholder?: string
}) {
  const [draft, setDraft] = useState('')
  const add = () => {
    const next = sanitizeText(draft.trim())
    if (next === '') return
    onChange([...values, next])
    setDraft('')
  }
  return (
    <Field label={label} hint={hint} issues={issues}>
      {values.map((value, index) => (
        <div className="list-row" key={index}>
          <input
            type="text"
            value={value}
            onChange={(e) =>
              onChange(values.map((v, i) => (i === index ? sanitizeText(e.target.value) : v)))
            }
          />
          <button
            type="button"
            className="btn btn-sm"
            onClick={() => onChange(values.filter((_, i) => i !== index))}
          >
            Remove
          </button>
        </div>
      ))}
      <div className="list-row">
        <input
          type="text"
          value={draft}
          placeholder={placeholder}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault()
              add()
            }
          }}
        />
        <button type="button" className="btn btn-sm" onClick={add} disabled={draft.trim() === ''}>
          Add
        </button>
      </div>
    </Field>
  )
}
