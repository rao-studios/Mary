import { useMemo } from 'react'
import type { JsonObject } from '../model/codec'
import type { SchemaIssue } from '../model/validate'
import { validatePackage } from '../model/validate'

export interface IssueIndex {
  all: SchemaIssue[]
  errors: SchemaIssue[]
  warnings: SchemaIssue[]
  isValid: boolean
  at(path: string): SchemaIssue[]
  under(prefix: string): SchemaIssue[]
}

const cache = new WeakMap<JsonObject, SchemaIssue[]>()

export function issuesFor(doc: JsonObject): SchemaIssue[] {
  const hit = cache.get(doc)
  if (hit) return hit
  const issues = validatePackage(doc)
  cache.set(doc, issues)
  return issues
}

export function indexIssues(issues: SchemaIssue[]): IssueIndex {
  const byPath = new Map<string, SchemaIssue[]>()
  for (const issue of issues) {
    const list = byPath.get(issue.path)
    if (list) list.push(issue)
    else byPath.set(issue.path, [issue])
  }
  return {
    all: issues,
    errors: issues.filter((i) => i.severity === 'error'),
    warnings: issues.filter((i) => i.severity === 'warning'),
    isValid: !issues.some((i) => i.severity === 'error'),
    at: (path) => byPath.get(path) ?? [],
    under: (prefix) =>
      issues.filter((i) => i.path === prefix || i.path.startsWith(`${prefix}.`) || i.path.startsWith(`${prefix}[`)),
  }
}

export function useIssues(doc: JsonObject | null): IssueIndex {
  return useMemo(() => indexIssues(doc ? issuesFor(doc) : []), [doc])
}
