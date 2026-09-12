//
//  path.ts
//  Ability Workshop
//
//  WHAT: Dotted/indexed paths — the same spelling the Swift validator emits —
//        plus immutable reads and writes over the raw tree.
//  PIN:  setIn copies only the spine. Untouched subtrees keep their identity,
//        which is what keeps export byte-identical and memoisation honest.
//

import type { JsonObject, JsonValue } from './codec'

export type Segment = string | number

/** "ability.triggers.tokens[3]" -> ["ability","triggers","tokens",3] */
export function parsePath(path: string): Segment[] {
  const segments: Segment[] = []
  for (const part of path.split('.')) {
    if (part === '') continue
    const match = part.match(/^([^[\]]*)((?:\[\d+\])*)$/)
    if (!match) {
      segments.push(part)
      continue
    }
    if (match[1] !== '') segments.push(match[1])
    for (const index of match[2].matchAll(/\[(\d+)\]/g)) segments.push(Number(index[1]))
  }
  return segments
}

export function formatPath(segments: Segment[]): string {
  return segments
    .map((segment, index) =>
      typeof segment === 'number' ? `[${segment}]` : index === 0 ? segment : `.${segment}`,
    )
    .join('')
}

export function getIn(root: JsonValue, path: string | Segment[]): JsonValue | undefined {
  const segments = typeof path === 'string' ? parsePath(path) : path
  let current: JsonValue | undefined = root
  for (const segment of segments) {
    if (current === null || current === undefined || typeof current !== 'object') return undefined
    if (typeof segment === 'number') {
      if (!Array.isArray(current)) return undefined
      current = current[segment]
    } else {
      if (Array.isArray(current)) return undefined
      current = (current as JsonObject)[segment]
    }
  }
  return current
}

function cloneShallow(node: JsonValue | undefined, segment: Segment): JsonValue {
  if (typeof segment === 'number') return Array.isArray(node) ? [...node] : []
  return node && typeof node === 'object' && !Array.isArray(node) ? { ...node } : {}
}

export function setIn<T extends JsonValue>(root: T, path: string | Segment[], value: JsonValue): T {
  const segments = typeof path === 'string' ? parsePath(path) : path
  if (segments.length === 0) return value as T

  const [head, ...rest] = segments
  const next = cloneShallow(root, head)
  const child = getIn(root, [head])
  const updated = rest.length === 0 ? value : setIn((child ?? null) as JsonValue, rest, value)
  if (typeof head === 'number') (next as JsonValue[])[head] = updated
  else (next as JsonObject)[head] = updated
  return next as T
}

export function deleteIn<T extends JsonValue>(root: T, path: string | Segment[]): T {
  const segments = typeof path === 'string' ? parsePath(path) : path
  if (segments.length === 0) return root

  const [head, ...rest] = segments
  const child = getIn(root, [head])
  if (child === undefined) return root

  const next = cloneShallow(root, head)
  if (rest.length === 0) {
    if (typeof head === 'number') (next as JsonValue[]).splice(head, 1)
    else delete (next as JsonObject)[head]
  } else {
    const updated = deleteIn(child as JsonValue, rest)
    if (typeof head === 'number') (next as JsonValue[])[head] = updated
    else (next as JsonObject)[head] = updated
  }
  return next as T
}

export function pushIn<T extends JsonValue>(root: T, path: string, value: JsonValue): T {
  const list = getIn(root, path)
  const array = Array.isArray(list) ? list : []
  return setIn(root, path, [...array, value])
}

/**
 * Lone surrogates survive `JSON.stringify` as `\udXXX` escapes and would make
 * Swift refuse the file. Strip them where text enters the document.
 */
export function sanitizeText(value: string): string {
  return value.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, '')
}
