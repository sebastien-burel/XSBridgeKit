// Phase 5 agent: several async calls in flight at once. Promise.all preserves
// input order regardless of completion order, so any id crosstalk would show.
(async () => {
  const r = await Promise.all([
    host.echo("a"), host.echo("b"), host.echo("c"), host.echo("d"),
  ]);
  print("all:" + r.join(","));
})();
