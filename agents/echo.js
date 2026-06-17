// Phase 3 agent: one async round-trip through Swift and back.
// Wrapped in an async IIFE because top-level await is a module-only feature and
// the harness evaluates agents as scripts (programs).
(async () => {
  const r = await host.echo("hi");
  print(r);
})();
