//
//  store.ts
//  Ability Workshop
//
//  WHAT: The document, its history, and where it came from.
//  PIN:  The document is the PARSED TREE, never a hydrated model. Hydrating
//        would materialise the defaults Swift deliberately omits and change
//        every digest at once.
//

import { useCallback, useSyncExternalStore } from 'react'
import type { JsonObject, JsonValue } from '../model/codec'
import { prettyEncode } from '../model/codec'
import { deleteIn, setIn } from '../model/path'

export type Origin =
  | { kind: 'new' }
  | { kind: 'template'; file: string }
  | { kind: 'imported'; filename: string }

export interface DocState {
  doc: JsonObject
  origin: Origin
  /** The exact bytes we opened, so "unchanged since import" is answerable. */
  baseline: string | null
  past: JsonObject[]
  future: JsonObject[]
  lastEdit: { path: string; at: number } | null
}

const HISTORY_LIMIT = 200
const COALESCE_MS = 500

let state: DocState | null = null
const listeners = new Set<() => void>()

function emit() {
  for (const listener of listeners) listener()
}

export function openDocument(doc: JsonObject, origin: Origin, baseline: string | null) {
  state = { doc, origin, baseline, past: [], future: [], lastEdit: null }
  emit()
}

export function closeDocument() {
  state = null
  emit()
}

export function getState(): DocState | null {
  return state
}

function commit(next: JsonObject, path: string, coalesce: boolean) {
  if (!state) return
  const now = Date.now()
  const merge =
    coalesce &&
    state.lastEdit !== null &&
    state.lastEdit.path === path &&
    now - state.lastEdit.at < COALESCE_MS
  const past = merge ? state.past : [...state.past, state.doc].slice(-HISTORY_LIMIT)
  state = { ...state, doc: next, past, future: [], lastEdit: { path, at: now } }
  emit()
}

/** Write a value at a path. Passing `undefined` deletes the key. */
export function edit(path: string, value: JsonValue | undefined, coalesce = false) {
  if (!state) return
  const next = value === undefined ? deleteIn(state.doc, path) : setIn(state.doc, path, value)
  if (next === state.doc) return
  commit(next, path, coalesce)
}

/** Apply an arbitrary transform as one undoable step. */
export function transform(label: string, fn: (doc: JsonObject) => JsonObject) {
  if (!state) return
  const next = fn(state.doc)
  if (next === state.doc) return
  commit(next, label, false)
}

export function undo() {
  if (!state || state.past.length === 0) return
  const past = [...state.past]
  const previous = past.pop() as JsonObject
  state = { ...state, doc: previous, past, future: [state.doc, ...state.future], lastEdit: null }
  emit()
}

export function redo() {
  if (!state || state.future.length === 0) return
  const [next, ...future] = state.future
  state = { ...state, doc: next, past: [...state.past, state.doc], future, lastEdit: null }
  emit()
}

export function isUnchanged(current: DocState): boolean {
  return current.baseline !== null && prettyEncode(current.doc) === current.baseline
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function useDocument(): DocState | null {
  return useSyncExternalStore(subscribe, getState, getState)
}

export function useField(path: string) {
  const current = useDocument()
  const set = useCallback(
    (value: JsonValue | undefined, coalesce = true) => edit(path, value, coalesce),
    [path],
  )
  return { doc: current?.doc ?? null, set }
}
