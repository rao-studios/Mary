//
//  factory.ts
//  Ability Workshop
//
//  WHAT: Mint a new, valid application-expertise `.mary` from a short template.
//  PIN:  Mirrors AbilityStudioPackageFactory.nativeApplication. The Studio has
//        exactly one creation lane because a DISCIPLINE's faculties are
//        compiled into Mary — a discipline authored here could never bind. The
//        workshop inherits that limit rather than emitting something inert.
//
//  Mirrors Sources/MaryApp/Components/Abilities/Studio/Model/AbilityStudioPackageFactory.swift
//

import type { JsonObject } from './codec'
import { CURRENT_FORMAT_VERSION, PACKAGE_FORMAT } from './codec'

export interface NativeApplicationTemplate {
  /** Portable package id, e.g. "obsidian". Also the ability id. */
  packageID: string
  /** Human title, e.g. "Obsidian". */
  title: string
  /** e.g. "md.obsidian". */
  bundleIdentifier: string
  /** e.g. "Obsidian.app". Optional. */
  bundleName?: string
  publisher: string
  /** #RRGGBB. */
  tint: string
  /** Discipline package ids this expertise extends, e.g. ["writing"]. */
  disciplines: string[]
}

/** ASCII words, lower-cased — the shared stem behind ids and callable names. */
function asciiWords(value: string): string[] {
  return value
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean)
}

export function portableStem(value: string, fallback: string): string {
  const words = asciiWords(value)
  return words.length > 0 ? words.join('-') : fallback
}

export function callableStem(value: string, fallback: string): string {
  const words = asciiWords(value)
  return words.length > 0 ? words.join('_') : fallback
}

export function bundleIdentifierIsValid(value: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$/.test(value)
}

export function suggestedPackageID(title: string): string {
  return portableStem(title, 'ability')
}

/**
 * Build the package. Key ordering does not matter — the codec sorts on write —
 * but the KEY SET does: an unknown key hard-fails the Swift decoder, and a key
 * Swift omits when false must stay omitted or every sealed digest shifts.
 */
export function createNativeApplicationPackage(
  template: NativeApplicationTemplate,
): JsonObject {
  const id = template.packageID
  const callablePrefix = callableStem(id, 'ability')
  const targetClass = `${id}-application`
  const skillID = `${id}.verify-surface`
  const capabilityID = `${id}.surface-verify`
  const adapterID = `${id}.managed-ui`
  const operation = `${callablePrefix}_verify_surface`

  const capability: JsonObject = {
    id: capabilityID,
    version: '1.0.0',
    title: `Verify ${template.title} Surface`,
    summary: 'Verify the focused native interaction surface.',
    effect: 'read',
    permissions: [],
    constraints: [
      { kind: 'requiresStage', value: 'true' },
      { kind: 'requiresFrontmostApplication', value: 'true' },
      { kind: 'allowedTargetClass', value: targetClass },
    ],
  }

  const skill: JsonObject = {
    id: skillID,
    version: '1.0.0',
    title: `Verify ${template.title} Surface`,
    summary:
      'Verify that the already-running application has a focused native interaction surface.',
    kind: 'effectful',
    access: 'seamless',
    inputs: [],
    outputs: [],
    requirements: {
      capabilities: [capabilityID],
      interactions: [],
      perceptions: [],
      optionalInteractions: [],
      optionalPerceptions: [],
      supportingAbilities: [],
      // `resolvesApplication` is omitted when false — Swift does the same, so
      // that adding the field did not invalidate every sealed digest at once.
    },
    routing: {
      eligibility: { kind: 'targetClass', value: targetClass, children: [] },
      preference: 0,
      conflictPolicy: 'highestEvidence',
      fallbacks: [],
      excludes: [],
    },
    execution: {
      kind: 'binding',
      bindings: [],
      steps: [],
      realizationPolicy: 'pluginRealizations',
    },
    modelExposure: {
      enabled: true,
      invocationName: operation,
      parameters: [],
      inheritsBindingContract: true,
    },
    usesStage: true,
    timeoutSeconds: 10,
  }

  const plugin: JsonObject = {
    id: id,
    version: '1.0.0',
    title: template.title,
    application: {
      id: id,
      title: template.title,
      bundleIdentifiers: [template.bundleIdentifier],
      bundleNames: template.bundleName ? [template.bundleName] : [],
      aliases: [],
      targetClasses: [targetClass],
      activation: 'activateRunning',
      contentInsets: { top: 0, leading: 0, bottom: 0, trailing: 0 },
      // NO `perception`. A workspace claim requires one of Mary's observation
      // adapters (prose/code/media/web surface or a corpus) to back it, and a
      // freshly taught application has none — the Swift factory omits it too.
    },
    adapter: {
      id: adapterID,
      version: '1.0.0',
      title: `${template.title} Native Interaction`,
      engine: 'macUI',
      permissions: ['accessibility'],
    },
    operations: [
      {
        operation: operation,
        title: `Verify ${template.title} Surface`,
        summary: 'Wait briefly, then verify the exact process still owns a focused window.',
        adapterID: adapterID,
        inputs: [],
        // `modifiers` is decoded with `decode`, not `decodeIfPresent`, so it is
        // required on EVERY step kind — a wait step included.
        steps: [{ id: 'settle', kind: 'wait', modifiers: [], durationSeconds: 0.1 }],
        postconditions: ['applicationFrontmost', 'applicationWindowAvailable'],
        timeoutSeconds: 10,
      },
    ],
    realizations: [
      {
        skillID: skillID,
        operation: operation,
        preference: 0,
        targetClasses: [targetClass],
      },
    ],
  }

  return {
    format: PACKAGE_FORMAT,
    formatVersion: CURRENT_FORMAT_VERSION,
    package: {
      id: id,
      version: '1.0.0',
      publisher: template.publisher,
      summary: `Teaches Mary how to operate ${template.title} through native faculties.`,
      minimumMaryVersion: '1.0.0',
    },
    ability: {
      id: id,
      version: '1.0.0',
      title: template.title,
      summary: `Expertise in ${template.title}, performed through Mary-owned native interaction.`,
      tint: template.tint,
      aliases: [],
      triggers: {
        tokens: [],
        phrases: [],
        negativeTokens: [],
        intentAliases: [],
        intentSeeds: {},
        seedFamilies: {},
      },
      skills: [skillID],
      operatingPolicy: {
        phases: ['identify-running-application', 'execute-native-recipe', 'verify'],
        guardrails: [
          `Never launch ${template.title}; operate only an already-running exact bundle identity.`,
          'Treat the package as data; Mary alone executes and verifies every step.',
        ],
        successSignals: ['Mary independently verified the declared postconditions'],
        stopConditions: ['user stop', `${template.title} not running`, 'foreground identity changed'],
        defaultSupportingAbilities: [],
        guardrailCategories: [],
      },
      routing: {
        eligibility: { kind: 'namedApplication', value: id, children: [] },
        preference: 100,
        conflictGroup: 'ability',
        conflictPolicy: 'preferFocusedWorkspace',
        fallbacks: [],
        excludes: [],
        requiredSourceResolution: 'application',
      },
      threadProjections: [],
      paradigm: 'applicationExpertise',
    },
    skills: [skill],
    capabilities: [capability],
    interactions: [],
    perceptions: [],
    valueTypes: [],
    threadProjections: [],
    dependencies: template.disciplines.map((packageID) => ({
      packageID,
      minimumVersion: '1.0.0',
      optional: false,
    })),
    fixtures: [],
    plugin,
  }
}
