import { useEffect, useRef, useState } from 'react'
import { CodecError, parsePackage } from '../model/codec'
import type { JsonObject } from '../model/codec'
import {
  bundleIdentifierIsValid,
  createNativeApplicationPackage,
  suggestedPackageID,
} from '../model/factory'
import { isValidIdentifier } from '../model/validate'
import { openDocument } from '../state/store'

interface TemplateRow {
  file: string
  id: string
  title: string
  summary: string
  tint: string
  paradigm: string | null
  skills: number
  fixtures: number
  operations: number
  hasPlugin: boolean
  bytes: number
}

const base = import.meta.env.BASE_URL

export function Start() {
  const [mode, setMode] = useState<'home' | 'new'>('home')
  const [templates, setTemplates] = useState<TemplateRow[]>([])
  const [error, setError] = useState<string | null>(null)
  const [hot, setHot] = useState(false)
  const fileInput = useRef<HTMLInputElement>(null)

  useEffect(() => {
    fetch(`${base}templates/index.json`)
      .then((r) => (r.ok ? r.json() : []))
      .then(setTemplates)
      .catch(() => setTemplates([]))
  }, [])

  const openText = (text: string, origin: 'imported' | 'template', name: string) => {
    try {
      const doc = parsePackage(text)
      openDocument(
        doc,
        origin === 'template' ? { kind: 'template', file: name } : { kind: 'imported', filename: name },
        text,
      )
      setError(null)
    } catch (e) {
      setError(e instanceof CodecError ? e.message : String(e))
    }
  }

  const openFile = async (file: File) => {
    if (!file.name.toLowerCase().endsWith('.mary')) {
      setError('Ability packages use the .mary extension.')
      return
    }
    openText(await file.text(), 'imported', file.name)
  }

  const openTemplate = async (row: TemplateRow) => {
    const response = await fetch(`${base}templates/${row.file}`)
    openText(await response.text(), 'template', row.file)
  }

  if (mode === 'new') return <NewAbility onCancel={() => setMode('home')} />

  return (
    <div
      className="wrap"
      onDragOver={(e) => {
        e.preventDefault()
        setHot(true)
      }}
      onDragLeave={() => setHot(false)}
      onDrop={(e) => {
        e.preventDefault()
        setHot(false)
        const file = e.dataTransfer.files[0]
        if (file) void openFile(file)
      }}
    >
      <div className="hero">
        <h1>Ability Workshop</h1>
        <p>
          Teaching Mary a new application is a <code>.mary</code> file, not a pull request. Write one
          here, edit one you already have, and take the file away with you. Everything runs in this
          tab — nothing is uploaded, and nothing touches your Mac.
        </p>
      </div>

      {error ? (
        <div className="banner warn">
          <strong>That file could not be opened.</strong>
          {error}
        </div>
      ) : null}

      <div className="doors">
        <button type="button" className="card door" onClick={() => setMode('new')}>
          <h3>Teach an application</h3>
          <p>
            Start from nothing. Name an app, say what to listen for, and leave with a valid package.
          </p>
        </button>
        <button type="button" className="card door" onClick={() => fileInput.current?.click()}>
          <h3>Open a .mary file</h3>
          <p>Import one you already have. Anything this editor does not show is kept exactly as it is.</p>
        </button>
        <div className={`card door dropzone${hot ? ' hot' : ''}`} style={{ display: 'grid', placeItems: 'center' }}>
          <p style={{ margin: 0 }}>…or drop a file anywhere on this page.</p>
        </div>
      </div>

      <input
        ref={fileInput}
        type="file"
        accept=".mary,application/json"
        hidden
        onChange={(e) => {
          const file = e.target.files?.[0]
          if (file) void openFile(file)
          e.target.value = ''
        }}
      />

      <h2 style={{ margin: '34px 0 6px' }}>Start from one that ships with Mary</h2>
      <p className="muted tiny" style={{ marginBottom: 14 }}>
        The seventeen packages Mary installs today. Open one to read how it is put together, or use
        it as a starting point.
      </p>
      <div className="gallery">
        {templates.map((row) => (
          <button type="button" className="tile" key={row.file} onClick={() => void openTemplate(row)}>
            <span className="swatch" style={{ background: row.tint }} />
            <span>
              <span className="tile-name">{row.title}</span>
              <br />
              <span className="tiny muted">
                {row.skills > 0 ? `${row.skills} skills` : 'no skills'}
                {row.operations > 0
                  ? ` · ${row.operations} action${row.operations === 1 ? '' : 's'}`
                  : ''}
                {row.fixtures > 0
                  ? ` · ${row.fixtures} sentence${row.fixtures === 1 ? '' : 's'}`
                  : ''}
              </span>
            </span>
          </button>
        ))}
      </div>
    </div>
  )
}

const TINTS = ['#3B7DD8', '#AE9060', '#46965A', '#C83C3C', '#7C3AED', '#1A73E8', '#6F7683']

function NewAbility({ onCancel }: { onCancel: () => void }) {
  const [title, setTitle] = useState('')
  const [bundleIdentifier, setBundle] = useState('')
  const [publisher, setPublisher] = useState('')
  const [tint, setTint] = useState(TINTS[0])
  const [touchedID, setTouchedID] = useState(false)
  const [packageID, setPackageID] = useState('')

  const derived = touchedID ? packageID : suggestedPackageID(title)
  const idOK = derived !== '' && isValidIdentifier(derived)
  const bundleOK = bundleIdentifierIsValid(bundleIdentifier)
  const ready = title.trim() !== '' && idOK && bundleOK && publisher.trim() !== ''

  const create = () => {
    const doc: JsonObject = createNativeApplicationPackage({
      packageID: derived,
      title: title.trim(),
      bundleIdentifier: bundleIdentifier.trim(),
      bundleName: `${title.trim()}.app`,
      publisher: publisher.trim(),
      tint,
      disciplines: [],
    })
    openDocument(doc, { kind: 'new' }, null)
  }

  return (
    <div className="wrap" style={{ maxWidth: 640 }}>
      <div className="step-head" style={{ marginTop: 28 }}>
        <h1>Teach an application</h1>
        <p className="lede">
          Mary recognises an application by its exact bundle identifier, never by what a window is
          called.
        </p>
      </div>

      <div className="card">
        <div className="field">
          <label>Application name</label>
          <input type="text" value={title} placeholder="Obsidian" onChange={(e) => setTitle(e.target.value)} />
        </div>
        <div className="field">
          <label>Bundle identifier</label>
          <input
            type="text"
            value={bundleIdentifier}
            placeholder="md.obsidian"
            style={{ fontFamily: 'var(--mono)' }}
            onChange={(e) => setBundle(e.target.value)}
          />
          <p className="hint">
            Find it with <code>osascript -e 'id of app "Obsidian"'</code> in Terminal.
          </p>
          {bundleIdentifier !== '' && !bundleOK ? (
            <p className="issue-inline error">
              A bundle identifier is dot-separated, like <code>com.apple.Safari</code>.
            </p>
          ) : null}
        </div>
        <div className="field">
          <label>Identifier</label>
          <input
            type="text"
            value={derived}
            style={{ fontFamily: 'var(--mono)' }}
            onChange={(e) => {
              setTouchedID(true)
              setPackageID(e.target.value)
            }}
          />
          <p className="hint">The filename, and the namespace every skill lives under.</p>
          {derived !== '' && !idOK ? (
            <p className="issue-inline error">
              Lower-case letters, numbers, dots and hyphens; must start with a letter.{' '}
              <code>invalid-id</code>
            </p>
          ) : null}
        </div>
        <div className="field">
          <label>Publisher</label>
          <input
            type="text"
            value={publisher}
            placeholder="Your name"
            onChange={(e) => setPublisher(e.target.value)}
          />
        </div>
        <div className="field">
          <label>Tint</label>
          <div className="chips">
            {TINTS.map((swatch) => (
              <button
                key={swatch}
                type="button"
                aria-label={swatch}
                onClick={() => setTint(swatch)}
                style={{
                  width: 26,
                  height: 26,
                  borderRadius: 6,
                  background: swatch,
                  border: swatch === tint ? '2px solid var(--lp-ink-primary)' : '1px solid var(--lp-platinum-4)',
                  cursor: 'pointer',
                }}
              />
            ))}
          </div>
        </div>
      </div>

      <div className="why">
        <strong>One creation lane, and it is an honest one.</strong> A <em>discipline</em> — coding,
        writing, browsing — needs faculties compiled into Mary, so no tool can conjure one from a
        file. What you can teach her is an application: what it is called, what to listen for, when
        to choose it, and which craft it joins. Seven of the nine applications Mary ships with
        declare no skills at all, so this is most of the file.
      </div>

      <div className="stepnav">
        <button type="button" className="btn" onClick={onCancel}>
          Back
        </button>
        <div className="spacer" />
        <button type="button" className="btn btn-primary" disabled={!ready} onClick={create}>
          Create the package
        </button>
      </div>
    </div>
  )
}
