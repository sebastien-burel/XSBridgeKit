// Phase 5 agent: mixed sequential calls (echo then stream) in one agent,
// exercising distinct ids back to back with no crosstalk.
(async () => {
  const a = await host.echo("first");
  print("echo:" + a);
  const full = await host.stream("p", (d) => { print("delta:" + d); });
  print("stream:" + full);
})();
