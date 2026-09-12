import { useEffect, useState } from 'react'
import type { JsonObject } from '../model/codec'
import { isSigned, prettyEncode, seal } from '../model/codec'
import type { IssueIndex } from './issues'

const SHIPPED = new Set([
  'apple-music', 'awareness', 'browsing', 'calendar', 'canvas', 'chrome', 'coding', 'dance',
  'multimedia', 'pages', 'reminders', 'safari', 'scrivener', 'textedit', 'window-management',
  'writing', 'xcode',
])

export function Review({
  doc,
  issues,
  unchanged,
}: {
  doc: JsonObject
  issues: IssueIndex
  unchanged: boolean
}) {
  const [text, setText] = useState('')
  const [digest, setDigest] = useState('')

  useEffect(() => {
    let live = true
    seal(doc).then((sealed) => {
      if (!live) return
      setText(prettyEncode(sealed))
      const integrity = sealed.integrity as JsonObject
      setDigest(String(integrity.digest))
    })
    return () => {
      live = false
    }
  }, [doc])

  const meta = (doc.package ?? {}) as JsonObject
  const id = String(meta.id ?? 'ability')
  const collides = SHIPPED.has(id)
  const signed = isSigned(doc)

  const download = () => {
    const blob = new Blob([text], { type: 'application/json' })
    const url = URL.createObjectURL(blob)
    const anchor = document.createElement('a')
    anchor.href = url
    anchor.download = `${id}.mary`
    anchor.click()
    URL.revokeObjectURL(url)
  }

  return (
    <>
      {signed ? (
        <div className="banner warn">
          <strong>This package was signed.</strong>
          Exporting drops the signature, because the browser holds no private key. Mary will still
          accept the file — she verifies the digest, and treats an unsigned package as unsigned.
        </div>
      ) : null}

      {collides ? (
        <div className="banner warn">
          <strong>Mary already ships an ability called “{id}”.</strong>
          Importing this through the Studio will be refused — import is additive, and it will not
          replace a package that is already installed. Editing a shipped ability is supported inside
          Mary, where saving writes a local override instead. To install this as something new, give
          it a different identifier.
        </div>
      ) : null}

      {unchanged ? (
        <div className="banner info">
          <strong>Unchanged since you opened it.</strong>
          These bytes are identical to the file you started from.
        </div>
      ) : null}

      <div className="card">
        <h3 style={{ marginBottom: 10 }}>The file</h3>
        <dl className="kv" style={{ marginBottom: 12 }}>
          <dt>name</dt>
          <dd>{id}.mary</dd>
          <dt>size</dt>
          <dd>{new Blob([text]).size.toLocaleString()} bytes</dd>
          <dt>sha256</dt>
          <dd>{digest}</dd>
        </dl>
        <div className="stepnav" style={{ marginTop: 0 }}>
          <button
            type="button"
            className="btn btn-primary"
            onClick={download}
            disabled={!issues.isValid || text === ''}
          >
            {issues.isValid
              ? 'Download .mary'
              : `Fix ${issues.errors.length} problem${issues.errors.length === 1 ? '' : 's'} to download`}
          </button>
          <button
            type="button"
            className="btn"
            onClick={() => navigator.clipboard?.writeText(text)}
            disabled={text === ''}
          >
            Copy JSON
          </button>
          {issues.warnings.length > 0 && issues.isValid ? (
            <span className="tiny muted">
              {issues.warnings.length} note{issues.warnings.length === 1 ? '' : 's'} — notes never
              block a download.
            </span>
          ) : null}
        </div>
      </div>

      <div className="card">
        <h3 style={{ marginBottom: 8 }}>Getting it into Mary</h3>
        <p className="tiny muted" style={{ marginBottom: 10 }}>
          Nothing here touches your Mac. This is a file you download and hand to Mary.
        </p>
        <p style={{ fontSize: 13 }}>
          <strong>1. Through the app.</strong> Mary → Abilities → Ability Studio → Import. She
          validates it against everything already installed and activates it for the next turn, with
          no restart.
        </p>
        <p style={{ fontSize: 13 }}>
          <strong>2. By hand.</strong> Put it in{' '}
          <code>~/Library/Application Support/Mary/Abilities/</code> — the writable directory that
          layers over what shipped.
        </p>
        <div className="why">
          There is no uninstall in the app yet. A package you install stays until you remove the file
          yourself.
        </div>
      </div>

      <div className="card">
        <h3 style={{ marginBottom: 8 }}>Canonical JSON</h3>
        <pre className="json">{text}</pre>
      </div>
    </>
  )
}
