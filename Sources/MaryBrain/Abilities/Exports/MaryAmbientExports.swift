// The reasoning layer is written in the ambient layer's vocabulary — worlds,
// facts, passages, containers, focus. Re-export it for the same reason
// MaryFoundation is re-exported: a consumer naming an AmbientWorld should not
// have to know which package it was declared in.
@_exported import MaryAmbient
