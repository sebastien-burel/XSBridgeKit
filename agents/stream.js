// Phase 4 agent: streaming through the reverse channel.
// onToken is invoked by Swift once per delta (in order); the Promise resolves
// with the full text once the stream ends.
(async () => {
  const full = await host.stream("hello", (delta) => {
    print("delta:" + delta);
  });
  print("full:" + full);
})();
