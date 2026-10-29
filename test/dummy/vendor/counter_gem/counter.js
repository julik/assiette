// Counts its own evaluations: a module loaded under two URLs runs twice
globalThis.counterEvaluations = (globalThis.counterEvaluations || 0) + 1

export function evaluations() {
  return globalThis.counterEvaluations
}
