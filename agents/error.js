// Phase 5 agent: the reject path. Swift rejects host.fail(); JS catches it.
// No longjmp escapes to Swift — the rejection stays in the JS world.
(async () => {
  try {
    await host.fail();
    print("no-throw");
  } catch (e) {
    print("caught:" + e);
  }
})();
