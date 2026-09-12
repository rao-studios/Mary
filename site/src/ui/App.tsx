import { useEffect, useState } from 'react'
import { getIn } from '../model/path'
import type { JsonObject } from '../model/codec'
import { closeDocument, isUnchanged, redo, undo, useDocument } from '../state/store'
import { useIssues } from './issues'
import type { IssueIndex } from './issues'
import { Review } from './Export'
import { Start } from './Start'
import { STEPS } from './steps'

export function App() {
  const state = useDocument()

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey) || e.key.toLowerCase() !== 'z') return
      e.preventDefault()
      if (e.shiftKey) redo()
      else undo()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  return (
    <div className="app">
      <TopBar />
      {state ? <Workbench /> : <Start />}
    </div>
  )
}

function TopBar() {
  const state = useDocument()
  const title = state ? String(getIn(state.doc, 'ability.title') ?? 'Untitled') : null
  return (
    <div className="topbar">
      <span className="brand">
        <span className="brand-mark">◇</span>
        Ability Workshop
      </span>
      {title ? (
        <>
          <span className="muted">/</span>
          <span style={{ fontSize: 13 }}>{title}</span>
        </>
      ) : null}
      <span className="topbar-spacer" />
      {state ? (
        <>
          <button className="btn btn-ghost btn-sm" onClick={undo} disabled={state.past.length === 0}>
            Undo
          </button>
          <button className="btn btn-ghost btn-sm" onClick={redo} disabled={state.future.length === 0}>
            Redo
          </button>
          <button
            className="btn btn-sm"
            onClick={() => {
              if (confirm('Close this ability? Anything you have not downloaded is lost.'))
                closeDocument()
            }}
          >
            Close
          </button>
        </>
      ) : (
        <a
          className="tiny muted"
          href="https://github.com/rao-studios/MaryOS"
          target="_blank"
          rel="noreferrer"
        >
          rao-studios/MaryOS
        </a>
      )}
    </div>
  )
}

const REVIEW = 'review'

function Workbench() {
  const state = useDocument()!
  const issues = useIssues(state.doc)
  const [active, setActive] = useState(state.origin.kind === 'new' ? STEPS[1].id : STEPS[0].id)

  const wizard = state.origin.kind === 'new'
  const index = STEPS.findIndex((s) => s.id === active)
  const step = STEPS[index]

  return (
    <>
      <div className="wrap bench">
        <nav className="rail">
          {STEPS.map((item, i) => {
            const scoped = item.scope.flatMap((path) => issues.under(path))
            const severity = scoped.some((s) => s.severity === 'error')
              ? 'error'
              : scoped.some((s) => s.severity === 'warning')
                ? 'warning'
                : null
            return (
              <button
                key={item.id}
                className="rail-item"
                aria-current={item.id === active}
                onClick={() => setActive(item.id)}
              >
                <span className="rail-num">{i + 1}</span>
                {item.title}
                {severity ? <span className={`rail-dot dot-${severity}`} /> : null}
              </button>
            )
          })}
          <button
            className="rail-item"
            aria-current={active === REVIEW}
            onClick={() => setActive(REVIEW)}
          >
            <span className="rail-num">✓</span>
            Review &amp; export
          </button>
        </nav>

        <main>
          <OriginBanner doc={state.doc} />
          {active === REVIEW ? (
            <>
              <div className="step-head">
                <h2>Review &amp; export</h2>
                <p className="lede">Nothing is installed from here. This is a file.</p>
              </div>
              <Review doc={state.doc} issues={issues} unchanged={isUnchanged(state)} />
            </>
          ) : step ? (
            <>
              <div className="step-head">
                <h2>{step.title}</h2>
                <p className="lede">{step.lede}</p>
              </div>
              {step.render({ doc: state.doc, issues })}
              <div className="stepnav">
                {index > 0 ? (
                  <button className="btn" onClick={() => setActive(STEPS[index - 1].id)}>
                    Back
                  </button>
                ) : null}
                <div className="spacer" />
                <button
                  className="btn btn-primary"
                  onClick={() => setActive(index + 1 < STEPS.length ? STEPS[index + 1].id : REVIEW)}
                >
                  {wizard ? 'Next' : 'Continue'}
                </button>
              </div>
            </>
          ) : null}
        </main>
      </div>
      <IssueDrawer issues={issues} onGoTo={setActive} />
    </>
  )
}

function OriginBanner({ doc }: { doc: JsonObject }) {
  const plugin = doc.plugin as JsonObject | undefined
  const corpus = doc.corpus
  if (!plugin && !corpus) return null
  const operations = Array.isArray(plugin?.operations) ? plugin.operations.length : 0
  return (
    <div className="banner info">
      <strong>This ability has parts this editor does not touch.</strong>
      Kept exactly as found, byte for byte:{' '}
      {[
        operations > 0
          ? `${operations} native action${operations === 1 ? '' : 's'}`
          : plugin
            ? 'a plugin block'
            : null,
        corpus ? 'a corpus' : null,
      ]
        .filter(Boolean)
        .join(' and ')}
      . Recipes are authored in Mary's own Studio, where she can watch the application while you
      {' '}record them.
    </div>
  )
}

function IssueDrawer({
  issues,
  onGoTo,
}: {
  issues: IssueIndex
  onGoTo: (step: string) => void
}) {
  const [open, setOpen] = useState(false)
  const { errors, warnings } = issues

  const stepFor = (path: string) =>
    STEPS.find((step) => step.scope.some((scope) => path === scope || path.startsWith(scope)))?.id

  return (
    <div className="drawer">
      <div className="drawer-bar" onClick={() => setOpen((v) => !v)}>
        <span
          className={`sev dot-${errors.length ? 'error' : warnings.length ? 'warning' : 'clear'}`}
          style={{ marginTop: 0 }}
        />
        <strong>
          {errors.length} problem{errors.length === 1 ? '' : 's'}
        </strong>
        <span className="muted">
          · {warnings.length} note{warnings.length === 1 ? '' : 's'}
        </span>
        <span className="topbar-spacer" />
        <span className="tiny muted">
          {issues.isValid ? 'Ready to download' : 'Download blocked'} — {open ? 'hide' : 'show'}
        </span>
      </div>
      {open ? (
        <div className="drawer-list">
          {issues.all.length === 0 ? (
            <p className="tiny muted" style={{ padding: '10px 0' }}>
              Nothing to report. Mary validates the whole installed set again on import — this is a
              first opinion, not the last word.
            </p>
          ) : (
            issues.all.map((issue, i) => {
              const target = stepFor(issue.path)
              return (
                <div className="issue-row" key={i}>
                  <span className={`sev dot-${issue.severity}`} />
                  <button
                    onClick={() => {
                      if (target) onGoTo(target)
                      setOpen(false)
                    }}
                  >
                    {issue.message}
                    <br />
                    <span className="path">{issue.path}</span>
                  </button>
                  <span className="code">{issue.code}</span>
                </div>
              )
            })
          )}
        </div>
      ) : null}
    </div>
  )
}
