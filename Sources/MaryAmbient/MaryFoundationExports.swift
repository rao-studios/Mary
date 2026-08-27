// The ambient layer speaks in schema vocabulary — InteractionID, PerceptionID,
// SourceScope, TypedRange, ValueEnvelope. Re-export the small, data-only schema
// module so consumers do not juggle a second import merely to name a piece of
// evidence, and so files moved into this package keep compiling unchanged.
@_exported import MaryFoundation
